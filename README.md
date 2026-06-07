# Self-Hosted GitHub Actions Runners on Amazon EKS

> Autoscaling, cost-optimized, **ephemeral** GitHub Actions runners on Amazon EKS, provisioned
> end-to-end with Terraform. Runners are managed by the **Actions Runner Controller (ARC)** in
> its modern `gha-runner-scale-set` mode; cluster compute scales on demand with **Karpenter**
> on **Spot** capacity; and the whole thing scales to **zero** when no jobs are running.

This README is deliberately exhaustive. It is meant to be the single source of truth for
anyone operating, extending, or debugging this stack — including future-you six months from
now who has forgotten why CoreDNS has a weird toleration. If you read only three sections,
read **[Architecture](#1-architecture-overview)**, **[How a job runs](#4-lifecycle-of-a-job-end-to-end)**,
and **[Challenges & Solutions](#12-challenges--solutions-the-debugging-journey)** — the last
one alone encodes days of debugging.

---

## Table of Contents

1. [Architecture overview](#1-architecture-overview)
2. [Core concepts & terminology](#2-core-concepts--terminology)
3. [Component deep-dives](#3-component-deep-dives)
   - [3.1 Networking (VPC)](#31-networking-vpc)
   - [3.2 EKS cluster & add-ons](#32-eks-cluster--add-ons)
   - [3.3 Provider authentication (the `exec` plugin)](#33-provider-authentication-the-exec-plugin)
   - [3.4 Actions Runner Controller (ARC)](#34-actions-runner-controller-arc)
   - [3.5 The GitHub App auth chain](#35-the-github-app-auth-chain)
   - [3.6 Karpenter](#36-karpenter)
   - [3.7 EKS Pod Identity vs IRSA](#37-eks-pod-identity-vs-irsa)
   - [3.8 The taint / toleration model](#38-the-taint--toleration-model)
4. [Lifecycle of a job (end-to-end)](#4-lifecycle-of-a-job-end-to-end)
5. [Repository layout & file-by-file walkthrough](#5-repository-layout--file-by-file-walkthrough)
6. [Configuration reference](#6-configuration-reference)
7. [Getting started](#7-getting-started)
   - [7.1 Prerequisites](#71-prerequisites)
   - [7.2 Create & install the GitHub App](#72-create--install-the-github-app)
   - [7.3 Example github.auto.tfvars](#73-example-githubautotfvars)
8. [Deployment runbook](#8-deployment-runbook)
   - [8.1 Teardown (and the Karpenter-orphan gotcha)](#81-teardown-and-the-karpenter-orphan-gotcha)
9. [Testing autoscaling](#9-testing-autoscaling)
10. [Cost optimization (the full model)](#10-cost-optimization-the-full-model)
11. [Observability & operations](#11-observability--operations)
12. [Challenges & solutions (the debugging journey)](#12-challenges--solutions-the-debugging-journey)
13. [Troubleshooting matrix](#13-troubleshooting-matrix)
14. [Security model](#14-security-model)
15. [Helper scripts](#15-helper-scripts)
16. [FAQ](#16-faq)
17. [Glossary](#17-glossary)
18. [Future improvements](#18-future-improvements)

---

## 1. Architecture overview

At a glance, four systems cooperate:

- **EKS** provides the Kubernetes control plane and a tiny fixed base of on-demand nodes.
- **ARC** turns GitHub job demand into Kubernetes pods (ephemeral runners).
- **Karpenter** turns unschedulable pods into right-sized **Spot** EC2 nodes, and removes them
  when idle.
- **GitHub** (the Actions service + Broker) dispatches jobs to runners that have registered.

```
                          GitHub Actions service  +  Broker (message bus)
                                   ▲        ▲
              register / JIT config│        │ long-poll for job messages
                                   │        │
┌──────────────────────────────────────────────────────────────────────────────────┐
│ EKS cluster: gha-runner-eks   (Kubernetes 1.36, region ap-south-1)                 │
│                                                                                    │
│  ns: arc-systems                              ns: arc-runners                      │
│  ┌───────────────────────────┐                ┌────────────────────────────────┐  │
│  │ ARC controller            │   reconciles   │ AutoscalingRunnerSet           │  │
│  │  (…-gha-rs-controller)    │───────────────▶│   └─ EphemeralRunnerSet        │  │
│  │ scale-set listener (1/job-│                │        └─ EphemeralRunner ×N   │  │
│  │  queue, talks to GitHub)  │                │             (one job per pod)  │  │
│  └───────────────────────────┘                └────────────────────────────────┘  │
│                                                                                    │
│  ns: karpenter                                                                     │
│  ┌───────────────────────────┐  watches Pending pods → launches/removes nodes     │
│  │ Karpenter controller      │──────────────────────────────────────────────┐    │
│  │  (Pod Identity → IAM)     │                                               │    │
│  └───────────────────────────┘                                               ▼    │
│                                                                                    │
│  ── Node topology ──────────────────────────────────────────────────────────────  │
│   Managed node group  (key "runners" = system base)   Karpenter-managed nodes      │
│   • on-demand, FIXED 1–2 × t3.medium                  • SPOT (fallback on-demand)   │
│   • taint: CriticalAddonsOnly=true:NoSchedule         • untainted                  │
│   • label: workload=system                            • x86 only (t3 / t3a)        │
│   • runs: CoreDNS, Karpenter, DaemonSets              • scale 0 → N → 0 on demand   │
│                                                       • runs: GHA runner pods ONLY  │
└──────────────────────────────────────────────────────────────────────────────────┘
                                   │
                          private subnets (3 AZ) → single NAT gateway → internet
```

### Design principles

1. **Ephemeral & isolated** — one job per pod, no state reuse, runners never share a node with
   control-plane components.
2. **Scale to zero** — when no jobs run, there are zero runner pods and zero runner nodes; only
   a tiny fixed base remains.
3. **Cheapest viable compute** — runners run on Spot, with broad instance diversity, packed
   efficiently and consolidated aggressively.
4. **Everything is code** — no click-ops; even the Karpenter version is resolved dynamically.
5. **Least privilege** — runner pods have no cluster RBAC and no IAM beyond what a runner needs.

---

## 2. Core concepts & terminology

| Term | Meaning |
|---|---|
| **ARC** | Actions Runner Controller — the Kubernetes operator that manages self-hosted runners. |
| **`gha-runner-scale-set`** | ARC's modern architecture (replaces the legacy `RunnerDeployment` model). A "scale set" is a pool of identical ephemeral runners addressed by a single name. |
| **Runner scale set name** | The unique label a job targets via `runs-on:`. Here it is **`gha-runner-scale-set`**. In this model it is the *only* label a runner has — there is no implicit `self-hosted` label. |
| **Ephemeral runner** | A runner that registers, runs exactly **one** job, then de-registers and the pod terminates. |
| **Listener** | A small pod (in `arc-systems`) that long-polls GitHub for job messages for one scale set and tells the controller how many runners to create. |
| **JIT config** | "Just-in-time" runner configuration (a base64 blob of registration token + settings) the controller injects so a pod can register without a long-lived PAT. |
| **Broker** | GitHub's message bus (`broker.actions.githubusercontent.com`) the runner connects to in order to receive its assigned job. |
| **Karpenter** | A Kubernetes-native node autoscaler that watches `Pending` pods and provisions right-sized EC2 nodes directly (no node groups / ASGs). |
| **NodePool / EC2NodeClass** | Karpenter v1 CRDs. The NodePool defines *what* may be launched (arch, capacity type, instance types, limits, disruption); the EC2NodeClass defines *how* (AMI, IAM role, subnet/SG discovery). |
| **Consolidation** | Karpenter's process of replacing/removing under-utilized or empty nodes to cut cost. |
| **Pod Identity** | The modern EKS mechanism to map a Kubernetes ServiceAccount to an IAM role (successor to IRSA). |
| **Service-linked role (SLR)** | An AWS-managed IAM role a service needs to operate; EC2 Spot requires `AWSServiceRoleForEC2Spot`. |
| **Taint / toleration** | A taint repels pods from a node; a matching toleration lets specific pods land there anyway. Used here to keep runners off the system base. |

---

## 3. Component deep-dives

### 3.1 Networking (VPC)

Defined in `vpc.tf` via `terraform-aws-modules/vpc/aws`.

- **CIDR:** `10.0.0.0/16`, spread across **3 AZs** (`ap-south-1a/b/c`).
- **Subnets:** private and public are derived with `cidrsubnet(cidr, 8, k)` / `cidrsubnet(cidr, 8, k+4)`,
  giving `/24`s per AZ. Nodes run in **private** subnets.
- **NAT:** **single NAT gateway** (`single_nat_gateway = true`) — egress for private nodes goes
  through one NAT instead of one-per-AZ. This is a deliberate cost choice (NAT is ~$0.045/hr +
  data each; three would triple the fixed cost). Trade-off: a single-AZ failure of the NAT
  affects egress; acceptable for a CI runner fleet.
- **Subnet tags:**
  - `kubernetes.io/role/elb` / `internal-elb` — standard EKS load-balancer discovery.
  - `karpenter.sh/discovery = <cluster_name>` on **private** subnets — this is how the Karpenter
    EC2NodeClass finds where to launch nodes (see [3.6](#36-karpenter)).

### 3.2 EKS cluster & add-ons

Defined in `eks.tf` via `terraform-aws-modules/eks/aws` v21.8.0.

- **Version:** Kubernetes **1.36**. (Chosen as the latest EKS-supported version at build time;
  verify current support with `aws eks describe-cluster-versions`.)
- **Access:** `enable_cluster_creator_admin_permissions = true` creates an EKS **access entry**
  granting the Terraform principal cluster-admin. `endpoint_public_access = true` exposes the API
  publicly (lock down with CIDR allow-lists for production). `enable_irsa = true` keeps IRSA
  available alongside Pod Identity.
- **Add-ons** (all `most_recent`, `before_compute` where they must exist before nodes):
  - **vpc-cni** — pod networking (ENIs). Has a blanket toleration, so it runs on the tainted base.
  - **kube-proxy** — service networking. Blanket toleration.
  - **eks-pod-identity-agent** — required for Pod Identity (used by Karpenter). Blanket toleration.
  - **coredns** — cluster DNS. **Given an explicit `CriticalAddonsOnly` toleration** via
    `configuration_values` so it can run on the tainted base — *critical*, because at zero-scale
    the base nodes may be the only nodes in the cluster (see [3.8](#38-the-taint--toleration-model)).
  - `resolve_conflicts_on_create/update = "OVERWRITE"` — required on v21 (the old `resolve_conflicts`
    was removed; see Challenge #4).
- **Node group** (map key `runners`, functioning as the **system base** — see Challenge #12 for
  why the key wasn't renamed): on-demand `t3.medium`, fixed `min=1 / desired=2 / max=2`, labeled
  `workload=system`, **tainted `CriticalAddonsOnly=true:NoSchedule`**, with `AmazonSSMManagedInstanceCore`
  attached for SSM access. Sized via dedicated `system_node_*` variables, fully decoupled from
  runner counts.
- **`node_security_group_tags`** add `karpenter.sh/discovery = <cluster_name>` so Karpenter can
  discover the SG to attach to new nodes.

### 3.3 Provider authentication (the `exec` plugin)

Defined in `versions.tf`. The Kubernetes, Helm, and kubectl providers authenticate to EKS using
the **exec credential plugin**:

```hcl
exec {
  api_version = "client.authentication.k8s.io/v1beta1"
  command     = "aws"
  args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", local.region]
}
```

**Why not a static token?** A `data.aws_eks_cluster_auth` token is minted when the data source is
read and is valid only ~15 minutes. Because the cluster *name* is a statically known value, that
data source resolves at **plan time** — before the ~12-minute control-plane build — so by the time
Terraform created namespaces the token had expired (`Unauthorized`). The `exec` plugin defers token
minting to **apply time, per call**, so it can never go stale. (See Challenge #2.)

Providers in use: `hashicorp/aws >= 6`, `hashicorp/kubernetes >= 2.30`, `hashicorp/helm >= 3`
(note: v3 uses the list form `set = [{name,value}]`), `gavinbunney/kubectl >= 1.14` (for raw CRDs),
and `hashicorp/http >= 3` (for the dynamic Karpenter version lookup).

### 3.4 Actions Runner Controller (ARC)

Two Helm releases (chart version **0.12.0**, repo `oci://ghcr.io/actions/actions-runner-controller-charts`),
defined in `helm_release_runner_controller.tf`:

1. **`gha-runner-scale-set-controller`** (ns `arc-systems`) — the operator. It reconciles the
   `AutoscalingRunnerSet` CRD and runs a **listener** pod per scale set.
2. **`gha-runner-scale-set`** (ns `arc-runners`) — declares one scale set. Key values:
   - `githubConfigUrl = https://github.com/<owner>/<repo>` — what the runners register to.
   - `githubConfigSecret.{github_app_id,github_app_installation_id,github_app_private_key}` — App auth.
   - `runnerScaleSetName = gha-runner-scale-set` — **the label jobs use in `runs-on:`**.
   - `minRunners` / `maxRunners` — from `min/max_runner_replicas` (here **0 / 10**).
   - `template.spec.containers[0]` — the runner pod spec: `name=runner`,
     `image=ghcr.io/actions/actions-runner:latest`, **`command=["/home/runner/run.sh"]`** (must be
     set explicitly — see Challenge #7), resources from `runner_deployment_*`
     (req `500m/1Gi`, lim `1000m/2Gi`), `restartPolicy=Never`.
   - `controllerServiceAccount.{namespace,name}` — points the scale set at the controller's SA.

**The listener** is the heartbeat: it holds a long-poll connection to GitHub, receives
`RunnerScaleSetJobMessages`, emits `statistics` (available/assigned/running jobs;
registered/busy/idle runners), and computes a target runner count that the controller applies to
the `EphemeralRunnerSet`.

**Ephemeral runner lifecycle:** controller creates pod → pod runs `run.sh` → consumes JIT config
→ connects to Broker → "Listening for Jobs" → runs one job → exits → controller cleans up. If a
pod exits *before* successfully running (e.g., wrong image, missing command), the controller marks
a **failure** and backs off — the symptom of several challenges below.

### 3.5 The GitHub App auth chain

Runners authenticate to GitHub as a **GitHub App installation**, not a PAT. The chain:

1. You provide **App ID**, **Installation ID**, and the App's **private key** (`.pem`).
2. The `local.github_app_private_key` resolution order is: inline `var.github_app_private_key` →
   `var.github_app_private_key_path` (if the file exists) → `./github-app-private-key.pem` → `""`.
3. These land in the chart as `githubConfigSecret`, which becomes a Kubernetes Secret in
   `arc-runners`.
4. The controller/listener use them to mint short-lived **installation tokens** and per-runner
   **JIT configs**. Individual runner pods never see the App private key — only their JIT config.

> The App needs **Administration: Read & write** on the repo (to register runners), plus
> **Metadata** and **Actions** read.

### 3.6 Karpenter

Defined in `karpenter.tf`. Karpenter replaces the "node group + cluster-autoscaler" pattern: it
watches `Pending` pods and launches **exactly** the nodes needed, then removes them when idle.

**IAM & wiring** (via `terraform-aws-modules/eks/aws//modules/karpenter` v21.8.0):
- **Controller IAM role** bound to the Karpenter ServiceAccount via **Pod Identity**
  (`create_pod_identity_association = true`) — no IRSA annotations needed.
- **Node IAM role** + instance profile for the EC2 nodes Karpenter launches (with SSM attached).
- **SQS interruption queue** + EventBridge rules (spot interruption, rebalance, instance state
  change, health events) so Karpenter gets the 2-minute Spot warning and **drains nodes
  gracefully** before reclamation.
- **EKS access entry** for the node role so Karpenter-launched nodes can join the cluster.

**Charts** (both from `oci://public.ecr.aws/karpenter`, version resolved dynamically):
- `karpenter-crd` — CRDs, installed separately so they upgrade cleanly with the controller.
- `karpenter` — the controller. Pinned to the base group via `nodeSelector: workload=system` and
  given the `CriticalAddonsOnly` toleration, so Karpenter **never runs on a node it manages**
  (which would risk it consolidating its own host).

**Dynamic version:** rather than hardcoding, `data.http.karpenter_latest_release` hits the GitHub
releases API and `local.karpenter_version` is
`coalesce(var.karpenter_version, trimprefix(...tag_name, "v"))`. The chart version tracks the
release version, so this drives both charts. Override `var.karpenter_version` to pin.

**EC2NodeClass `default`** (the *how*):
- `amiSelectorTerms: [{ alias = "al2023@latest" }]` — always the latest AL2023 EKS-optimized AMI.
- `role` = the Karpenter node IAM role.
- `subnetSelectorTerms` / `securityGroupSelectorTerms` discover by the `karpenter.sh/discovery`
  tag set on private subnets and the node SG.

**NodePool `default`** (the *what*):
- `requirements`: `arch In [amd64]`, `os In [linux]`,
  `capacity-type In [spot, on-demand]` (**spot-first**), `instance-type In [t3.*, t3a.*]`.
- `limits.cpu = 100` — a hard guardrail on total provisioned vCPU.
- `disruption: { consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: 30s }`.
- `expireAfter: 720h` — nodes are recycled after 30 days for freshness/patching.

**Spot prerequisite:** the account must have the EC2 Spot **service-linked role**
(`AWSServiceRoleForEC2Spot`); `aws_iam_service_linked_role.spot` creates it. Without it, Spot
`CreateFleet` fails with `AuthFailure.ServiceLinkedRoleCreationNotPermitted` and Karpenter
silently falls back to on-demand (see Challenge #13).

### 3.7 EKS Pod Identity vs IRSA

This stack uses **Pod Identity** for Karpenter (and enables IRSA too). Both map a Kubernetes
ServiceAccount to an IAM role, but:

| | IRSA | Pod Identity |
|---|---|---|
| Mechanism | OIDC provider + SA annotation (`eks.amazonaws.com/role-arn`) | `eks-pod-identity-agent` add-on + an association resource |
| Setup | Per-cluster OIDC provider, trust policy references it | One add-on, simple association; no annotation |
| Cross-cluster reuse | Trust policy tied to one OIDC issuer | Role reusable across clusters |
| Here | available (`enable_irsa=true`) | **used for Karpenter** (`create_pod_identity_association=true`) |

Pod Identity is the modern default and removes the OIDC-trust-policy boilerplate, which is why the
Karpenter Helm release needs no IRSA annotation — just `serviceAccount.name` matching the
association.

### 3.8 The taint / toleration model

This is the crux of the cost design and the most failure-prone part, so it's spelled out fully.

**Goal:** runners must run on cheap Spot nodes, never on the on-demand base; system components
must keep running even when the base is the *only* node group (at zero-scale).

**Mechanism:** the base node group carries the taint **`CriticalAddonsOnly=true:NoSchedule`**.
A `NoSchedule` taint repels any pod that doesn't explicitly tolerate it.

| Workload | On tainted base? | How |
|---|---|---|
| **GHA runner pods** | ❌ never | No toleration → repelled → go `Pending` → Karpenter launches Spot |
| **CoreDNS** | ✅ | Explicit `CriticalAddonsOnly` toleration via add-on `configuration_values` |
| **Karpenter controller** | ✅ (pinned here) | Toleration **+** `nodeSelector: workload=system` |
| **vpc-cni / kube-proxy / pod-identity** | ✅ | Built-in **blanket** toleration (`operator: Exists`) — verified with `kubectl` |

**Why CoreDNS needs the toleration specifically:** once `minRunners=0`, an idle cluster has *no*
Spot nodes. If CoreDNS could only run on untainted nodes, it would be unschedulable and DNS would
break cluster-wide. The explicit toleration lets it run on the base. (See Challenge #11.)

**Why Karpenter is pinned to the base:** if Karpenter ran on a Spot node it manages, a
consolidation/interruption of that node could take the controller down mid-decision. Pinning it to
the stable base via `nodeSelector` avoids self-disruption.

---

## 4. Lifecycle of a job (end-to-end)

A step-by-step trace, with the observable signals at each step:

```
1. Workflow job queued (runs-on: gha-runner-scale-set)
        │
2. Listener (arc-systems) receives "Job assigned"     ── log: statistics{totalAssignedJobs:1}
        │
3. Controller scales EphemeralRunnerSet → creates EphemeralRunner pod(s) in arc-runners
        │
4. Runner pod has no toleration for the base taint → Pending   ── kubectl get pods: Pending
        │
5. Karpenter sees Pending pod → computes & launches a Spot node ── log: "launched nodeclaim" capacity-type:spot
        │
6. Node joins; pod schedules; runs /home/runner/run.sh
        │
7. Runner pulls JIT config, connects to Broker         ── pod log: "√ Connected to GitHub"
        │
8. Runner reaches "Listening for Jobs"                 ── pod log: "Listening for Jobs"
        │                                                  listener: totalIdleRunners:1
9. GitHub dispatches the job to the runner             ── listener: totalBusyRunners:1, totalRunningJobs:1
        │
10. Job runs to completion (one job only — ephemeral)
        │
11. Runner de-registers, pod exits, controller cleans up
        │
12. Demand drops → ARC scales to minRunners (0) → pods gone
        │
13. Karpenter sees empty node → consolidates after 30s → Spot node terminated
        │
14. Cluster back to fixed base only (zero runner cost)
```

Failure modes map cleanly onto these steps: stuck at step 1 = `runs-on` mismatch (Challenge #5);
stuck at step 4/5 with on-demand instead of Spot = missing SLR (#13); pod cycles between 6–8
without reaching "Listening" = missing command (#7); reaches step 8 then dies with `403` = stale
image (#8).

---

## 5. Repository layout & file-by-file walkthrough

```
.
├── versions.tf                         # Terraform + provider versions; provider configs (exec auth)
├── vpc.tf                              # VPC, subnets, single NAT, Karpenter subnet discovery tags
├── eks.tf                              # EKS cluster, add-ons, tainted system node group, SG tag
├── k8s_namespace.tf                    # arc-runners + arc-systems namespaces
├── helm_release_runner_controller.tf  # ARC controller + scale set + runner template values
├── karpenter.tf                        # Spot SLR, dynamic version, IAM, charts, NodePool/EC2NodeClass
├── locals.tf                           # all defaults via coalesce()
├── variables.tf                        # all inputs (default = null)
├── github.auto.tfvars                  # LOCAL, git-ignored overrides (App IDs, key path, runner counts)
└── .github/workflows/
    ├── test.yml                        # smoke test (runs-on: gha-runner-scale-set)
    └── scale-test.yml                  # 10-way matrix load test
```

> **Local-only (git-ignored, not committed):** `establish_local_connection.sh` (kubeconfig
> helper), `validate_script.sh` (verifies the in-cluster App secret), and `wtf.sh` (health
> check) — documented in [§15](#15-helper-scripts). Keep them locally; nothing in the Terraform
> flow depends on them.

**`versions.tf`** — pins Terraform ≥ 1.13 and all providers; configures `aws`, and the three K8s
providers (`kubernetes`, `helm`, `kubectl`) with `exec` auth, plus `http`.

**`vpc.tf`** — one module call. Note the `for k, v in local.availability_zones` subnet math and the
discovery tag on private subnets.

**`eks.tf`** — cluster, add-ons (incl. the CoreDNS toleration `configuration_values`), the system
node group (taint + label + `system_node_*` sizing), and `node_security_group_tags`. Also declares
`data.aws_caller_identity` and `data.aws_partition` used for ARNs.

**`k8s_namespace.tf`** — `arc-runners` and `arc-systems`, each `depends_on = [module.eks_cluster]`.

**`helm_release_runner_controller.tf`** — the two ARC releases and the full runner pod template
expressed as Helm `set` entries. This is where the `command` fix and the deployment-resource fix
live.

**`karpenter.tf`** — top to bottom: the Spot SLR, the dynamic-version data source, the Karpenter
IAM/queue module, the CRD + controller Helm releases (with nodeSelector/tolerations), and the
`EC2NodeClass` + `NodePool` rendered with `yamlencode`.

**`locals.tf` / `variables.tf`** — the configuration surface; see [§6](#6-configuration-reference).

---

## 6. Configuration reference

> Pattern: every value is `variable "x" { default = null }` + `local.x = coalesce(var.x, "<default>")`.
> Override via `github.auto.tfvars` (git-ignored, auto-loaded) or `-var`.

### Core / networking
| Variable | Default | Description |
|---|---|---|
| `region` | `ap-south-1` | AWS region. |
| `short_name` | `gha-runner` | Prefix for resource names; `cluster_name = <short_name>-eks`. |
| `availability_zones` | `[ap-south-1a, -1b, -1c]` | AZs for subnets. |
| `cidr` | `10.0.0.0/16` | VPC CIDR. |
| `namespace` | `runner` | Generic namespace local (ARC uses `arc-runners`/`arc-systems` explicitly). |

### GitHub App / runners
| Variable | Default | Description |
|---|---|---|
| `github_repository` | `blue-samarth/Github_Actions_Runners` | Repo the scale set registers to. |
| `github_owner` | `blue-samarth` | Owner. |
| `github_app_id` | `123456` (dummy) | **Override.** GitHub App ID. |
| `github_app_installation_id` | `12345678` (dummy) | **Override.** Installation ID. |
| `github_app_private_key` | `null` (sensitive) | Inline key (highest precedence). |
| `github_app_private_key_path` | `null` | Path to `.pem` (used if inline is null). |
| `runner_image` | `ghcr.io/actions/actions-runner:latest` | **Keep current** (Challenge #8). |
| `min_runner_replicas` | `1` → **`0`** in tfvars | ARC `minRunners`. `0` = scale to zero. |
| `max_runner_replicas` | `5` → **`10`** in tfvars | ARC `maxRunners` (concurrency cap). |
| `runner_deployment_resources_limits_cpu` | `1000m` | Runner pod CPU limit. |
| `runner_deployment_resources_limits_memory` | `2Gi` | Runner pod memory limit. |
| `runner_deployment_resources_requests_cpu` | `500m` | Runner pod CPU request (drives Karpenter sizing). |
| `runner_deployment_resources_requests_memory` | `1Gi` | Runner pod memory request. |
| `runner_controller_resources_*` | `500m/512Mi` lim, `250m/256Mi` req | Controller pod resources. |

### System (base) node group — decoupled from runners
| Variable | Default | Description |
|---|---|---|
| `system_node_instance_types` | `["t3.medium"]` | Base instance types. |
| `system_node_min_size` | `1` | Base min. |
| `system_node_desired_size` | `2` | Base desired (CoreDNS + Karpenter HA). |
| `system_node_max_size` | `2` | Base max. |

### Karpenter
| Variable | Default | Description |
|---|---|---|
| `karpenter_version` | **dynamic (latest)** | Resolved from GitHub releases; override to pin. |
| `karpenter_namespace` | `karpenter` | Controller namespace. |
| `karpenter_node_instance_types` | `t3.{medium,large,xlarge}` + `t3a.*` | x86 only. |
| `karpenter_capacity_types` | `["spot","on-demand"]` | Spot-first, on-demand fallback. |
| `karpenter_cpu_limit` | `100` | NodePool total vCPU cap. |

---

## 7. Getting started

The full path from nothing to a working runner fleet. Do **7.1–7.3** once, then run the
[Deployment runbook](#8-deployment-runbook).

### 7.1 Prerequisites

- **Terraform** ≥ 1.13, **AWS CLI v2** (authenticated to the target account), **kubectl**, **helm**.
- An AWS account with quota for EKS, NAT, and on-demand **+ Spot** EC2.
- Permission to create the **EC2 Spot service-linked role** (this stack creates it; if it already
  exists account-wide, run `terraform import aws_iam_service_linked_role.spot <role-arn>` instead).
- **Do not** run Terraform as the account root user — use a scoped IAM principal.

### 7.2 Create & install the GitHub App

Runners authenticate as a **GitHub App installation** (more secure and higher API rate limits than
a PAT). GitHub has **no API to create an App non-interactively**, so this part is one-time and
manual. You'll come away with three values + a private key file.

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
   (for an org: **Org Settings → Developer settings → GitHub Apps**).
2. **GitHub App name:** anything unique (e.g., `my-eks-runners`). **Homepage URL:** your repo URL.
3. **Webhook:** **uncheck "Active"** — ARC doesn't need webhooks.
4. **Permissions** — grant the minimum ARC requires:
   - *For repository-level runners* — **Repository permissions:**
     - **Administration → Read and write**  (register / remove runners)
     - **Metadata → Read-only**  (auto-selected)
     - **Actions → Read-only**
   - *For organization-level runners* — additionally **Organization permissions → Self-hosted
     runners → Read and write**.
5. **Where can this app be installed:** *Only on this account*.
6. Click **Create GitHub App**.
7. On the App's **General** page, copy the **App ID** (e.g., `2282659`) → this is `github_app_id`.
8. Still on **General → Private keys → Generate a private key**. A `.pem` downloads — this is your
   `github_app_private_key_path`. Keep it safe; it's a credential.
9. Left sidebar → **Install App** → **Install** on your account → choose **Only select
   repositories**, pick the repo(s) the runners will serve → **Install**.
10. After installing, the browser URL is
    `https://github.com/settings/installations/<INSTALLATION_ID>` — that number is your
    `github_app_installation_id` (e.g., `94439212`). (Findable later via the App → *Install App* →
    **Configure**.)

Put the `.pem` somewhere this repo can read it (the repo root is simplest) and reference it by path
in tfvars (next step).

### 7.3 Example `github.auto.tfvars`

Create **`github.auto.tfvars`** in the repo root. It is **git-ignored** and **auto-loaded** by
Terraform — so your secrets are never committed and you never pass `-var-file`. Only the four GitHub
values are **required**; everything else has a sensible default in `locals.tf` and is shown
commented for reference.

```hcl
# ── REQUIRED: GitHub App identity (from step 7.2) ───────────────────────────
github_repository           = "your-org/your-repo"                 # repo the runners serve
github_app_id               = "2282659"                            # App → General → App ID
github_app_installation_id  = "94439212"                           # from the install URL
github_app_private_key_path = "./my-eks-runners.private-key.pem"   # the downloaded .pem

# ── OPTIONAL: runner scaling (defaults: min 1, max 5) ───────────────────────
min_runner_replicas = 0      # 0 = scale to zero when idle (cheapest)
max_runner_replicas = 10     # hard cap on concurrent runners

# ── OPTIONAL: region / naming (defaults shown) ──────────────────────────────
# region     = "ap-south-1"
# short_name = "gha-runner"   # cluster name becomes "<short_name>-eks"

# ── OPTIONAL: Karpenter / cost knobs (defaults shown) ───────────────────────
# karpenter_capacity_types      = ["spot", "on-demand"]   # spot-first, on-demand fallback
# karpenter_node_instance_types = ["t3.medium", "t3.large", "t3.xlarge", "t3a.medium", "t3a.large", "t3a.xlarge"]
# karpenter_cpu_limit           = "100"                   # NodePool total vCPU cap
# karpenter_version             = null                    # null = latest release (resolved dynamically)

# ── OPTIONAL: system/base node group (defaults shown) ───────────────────────
# system_node_instance_types = ["t3.medium"]
# system_node_min_size       = 1
# system_node_desired_size   = 2
# system_node_max_size       = 2

# ── OPTIONAL: per-runner pod resources (defaults shown) ─────────────────────
# runner_deployment_resources_requests_cpu    = "500m"
# runner_deployment_resources_requests_memory = "1Gi"
# runner_deployment_resources_limits_cpu      = "1000m"
# runner_deployment_resources_limits_memory   = "2Gi"
```

> **Alternative to a key file:** set `github_app_private_key` (the PEM *contents*) instead of
> `github_app_private_key_path`. Either way it stays in the git-ignored tfvars and out of version
> control. For stronger isolation see the secret-hardening options in
> [Future improvements](#18-future-improvements).

---

## 8. Deployment runbook

```bash
# 1) Provide real values in github.auto.tfvars (git-ignored, auto-loaded):
cat > github.auto.tfvars <<'EOF'
github_repository           = "<owner>/<repo>"
github_app_id               = "<app id>"
github_app_installation_id  = "<installation id>"
github_app_private_key_path = "./<your-app>.private-key.pem"
min_runner_replicas         = 0
max_runner_replicas         = 10
EOF

# 2) Init (downloads EKS+Karpenter modules and the http provider)
terraform init

# 3) Review & apply
terraform fmt
terraform validate
terraform plan          # expect a clean plan; no destroys on a steady cluster
terraform apply

# 4) Kubeconfig
aws eks update-kubeconfig --name gha-runner-eks --region ap-south-1 --alias gha-runner-eks

# 5) Verify the control plane is healthy
kubectl get pods -n arc-systems                    # controller + listener should be Running
kubectl get autoscalingrunnerset -n arc-runners    # the scale set should exist
kubectl logs -n arc-systems -l app.kubernetes.io/component=runner-scale-set-listener --tail=5 | grep statistics

# 6) Push the workflow so GitHub runs the correct runs-on (see Challenge #6)
git add .github/workflows/ && git commit -m "ci: self-hosted runners" && git push
```

> **Order matters for first apply:** the EKS control plane takes ~10–15 min; the `exec` provider
> auth handles token freshness so the namespace/Helm/Karpenter resources apply afterward without
> the `Unauthorized` error described in Challenge #2.

### 8.1 Teardown (and the Karpenter-orphan gotcha)

`terraform destroy` works, but there's one trap: **Karpenter-launched nodes are not in Terraform
state** — Karpenter creates them dynamically from pending pods. A naive destroy removes the
Karpenter *controller* but leaves its EC2 nodes running. Those orphans then block VPC/subnet/SG
deletion (`DependencyViolation`) and the Spot SLR deletion (`Open or Active spot instance requests
found`).

**Clean teardown — drain Karpenter first, then destroy:**

```bash
# 1) Make Karpenter scale its nodes to zero
kubectl delete nodepool --all
kubectl delete nodeclaim --all          # remove any stragglers
kubectl get nodes -w                    # wait until only the system base nodes remain

# 2) Destroy
terraform destroy
```

(Equivalently: set `min_runner_replicas = 0` / `max_runner_replicas = 0`, let consolidation drain
the runner nodes, then destroy.)

**If you already destroyed and hit orphans**, terminate the leftover Karpenter instances by tag and
re-run — terminating one-time Spot instances also closes their Spot requests:

```bash
aws ec2 describe-instances --region ap-south-1 \
  --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
            "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text \
| xargs -r aws ec2 terminate-instances --region ap-south-1 --instance-ids
terraform destroy
```

**Provider-connectivity escape hatch.** If `destroy` fails because the Kubernetes providers can't
reach the cluster API (e.g., `dial tcp ... i/o timeout` on the EKS endpoint — a VPN/network path
issue), you don't need the cluster API to tear down AWS infra. In-cluster objects die with the
cluster, so drop them from state and destroy with AWS APIs only:

```bash
terraform state rm \
  helm_release.arc_controller helm_release.arc_runner_scale_set \
  helm_release.karpenter helm_release.karpenter_crd \
  kubectl_manifest.karpenter_node_class kubectl_manifest.karpenter_node_pool \
  kubernetes_namespace_v1.namespace_arc_runners kubernetes_namespace_v1.namespace_arc_systems
terraform destroy
```

**Always confirm no billable leftovers** (NAT gateways + EIPs bill until gone — don't leave a
half-finished destroy):

```bash
aws ec2 describe-nat-gateways --region ap-south-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses    --region ap-south-1 --query 'Addresses[].AllocationId'
aws ec2 describe-instances    --region ap-south-1 --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId'
```

All three should return empty.

---

## 9. Testing autoscaling

`scale-test.yml` fans out into **10 parallel jobs** (`matrix.instance: [1..10]`), each holding for
`sleep 180`, forcing all ten to run concurrently — exercising ARC scaling *and* Karpenter node
provisioning at once.

```bash
# Trigger: Actions → "Scale Test" → Run workflow (workflow_dispatch)

# Runner scaling (ARC): 0 → up to maxRunners
kubectl get pods -n arc-runners -w

# Node scaling (Karpenter): spot nodes appear, then consolidate away
kubectl get nodeclaims -w
kubectl get nodes -L workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# Karpenter decisions (launch / consolidate / spot fallback)
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f \
  | grep -iE "launched|nodeclaim|capacity-type|disrupt|insufficient"

# Listener's demand view
kubectl logs -n arc-systems -l app.kubernetes.io/component=runner-scale-set-listener -f \
  | grep -i statistics
```

**A real run from this cluster** (validated): ARC created 10 runner pods (hit `maxRunners=10`),
Karpenter launched a `t3a.medium` then a `t3a.xlarge` to fit them, all runners landed on Karpenter
nodes (none on the tainted base), and the listener reported
`totalAssignedJobs:10, totalRegisteredRunners:10, totalBusyRunners:N`. After the jobs finished,
runners terminated and Karpenter consolidated the empty nodes away.

> **Concurrency cap:** `maxRunners=10` means only 10 jobs run at once; trigger more and the rest
> queue (expected back-pressure, not a failure).

---

## 10. Cost optimization (the full model)

### Levers applied

| Lever | Where | Effect |
|---|---|---|
| **Spot-first** | `karpenter_capacity_types = ["spot","on-demand"]` | ~65–75% off runner compute; on-demand only if Spot is unavailable. |
| **Scale to zero** | `min_runner_replicas = 0` | No warm runner — and no node for it — between jobs. |
| **Instance diversity + AMD** | `t3a.*` alongside `t3.*` | Bigger Spot pool (fewer interruptions, better price); t3a ~10% under t3. |
| **Tainted system-only base** | `CriticalAddonsOnly` taint | All runner load forced onto Spot; base stays small & on-demand. |
| **Decoupled base sizing** | `system_node_*` | Base is a tiny fixed size, independent of runner counts. |
| **Consolidation** | `WhenEmptyOrUnderutilized`, `30s` | Empty/under-used nodes removed automatically. |
| **NodePool vCPU cap** | `karpenter_cpu_limit = 100` | Guardrail against runaway node spend. |
| **Single NAT gateway** | `single_nat_gateway = true` | One NAT instead of per-AZ. |
| **Spot interruption handling** | SQS + EventBridge | Graceful drain on the 2-min notice → jobs reschedule cleanly. |

### Savings model

Split your bill into **fixed** (unchanged) and **variable / runner** (optimized) costs:

- **Fixed (unchanged):** EKS control plane (~$0.10/hr ≈ $73/mo), single NAT (~$0.045/hr + data),
  and the ~2 on-demand `t3.medium` base nodes.
- **Variable (runner compute):** Spot + diversity + scale-to-zero apply here.

Approximate savings on the **runner-compute** line:

| Utilization | Drivers | Savings |
|---|---|---|
| High (busy most of the day) | Spot (~70%) + t3a (~10%) | **~73%** |
| Typical CI (busy ~15–25%) | Spot **+** idle-elimination | **~85–92%** |

On the **total** bill the headline is diluted by the fixed floor → realistically **~30–60%**,
trending toward the high end the more runner-heavy your spend is.

### Why **not** Graviton/ARM

ARM (`t4g/m7g`) would add ~20% on top of Spot, **but these runners build Docker images**. On ARM,
`docker build` produces **arm64** by default; serving x86 consumers would require multi-arch
`buildx` + QEMU emulation — slower, more complex, more failure modes. The NodePool is therefore
pinned to **x86** (`arch In [amd64]`, `t3/t3a` only) so builds stay native. A deliberate trade of
~20% for build correctness.

---

## 11. Observability & operations

**The single most useful signal** is the listener's `statistics` line — it's GitHub's own view of
your fleet:

```bash
kubectl logs -n arc-systems -l app.kubernetes.io/component=runner-scale-set-listener --tail=20 \
  | grep statistics
# totalAvailableJobs / totalAssignedJobs / totalRunningJobs
# totalRegisteredRunners / totalBusyRunners / totalIdleRunners
```

Interpreting it:
- `registered > 0` but `idle == 0` and `busy == 0` → runners registered but **not listening**
  (missing command / deprecated image — Challenges #7, #8).
- `assigned > 0`, `running == 0`, then jobs `canceled` → runners never came online to take the job.
- `idle == minRunners` and no nodes → healthy zero-scale.

Other essentials:

```bash
# Runner pods + which node they're on
kubectl get pods -n arc-runners -o wide

# Node topology (base vs spot)
kubectl get nodes -L workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# Karpenter inventory & decisions
kubectl get nodepool,ec2nodeclass,nodeclaims
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=80

# A failing runner: read PAST "Listening for Jobs"
kubectl logs -n arc-runners <pod>
kubectl describe ephemeralrunner -n arc-runners
```

`wtf.sh` automates a full health sweep; `validate_script.sh` checks the App secret.

---

## 12. Challenges & solutions (the debugging journey)

The real problems hit while building this, in roughly the order they surfaced. Each was
non-obvious; together they are the most valuable part of this document.

### 1. GitHub App private key arrived empty → chart refused to install
**Symptom:** `A valid .Values.githubConfigSecret is required … github_app_installation_id and github_app_private_key`.
**Cause:** credentials lived in `github.tfvars`, which Terraform **does not auto-load** (only
`terraform.tfvars` and `*.auto.tfvars`). `terraform apply` without `-var-file` fell back to dummy
IDs and an **empty** private key, which the chart rejects.
**Fix:** rename to **`github.auto.tfvars`** (auto-loaded, still git-ignored). Always confirm the
key is non-empty before suspecting the chart.

### 2. `Unauthorized` / "server has asked for credentials" mid-apply
**Symptom:** cluster created, then namespaces/Helm failed `Unauthorized` / `cluster unreachable`.
**Cause:** providers used a **static** `data.aws_eks_cluster_auth` token. Because the cluster name
is statically known, the data source resolved at **plan time**, minting a token before the
~12-minute build; it had **expired** (15-min TTL) by the time namespaces were created.
**Fix:** switch all K8s providers to the **`exec` plugin** (`aws eks get-token`) — fresh token per
call at apply time. Removed the now-unused data source. (See [3.3](#33-provider-authentication-the-exec-plugin).)

### 3. Invalid `depends_on` reference
**Cause:** `depends_on = [module.eks_cluster.aws_eks_addon]` — you can't reference a resource
*inside* a module unless it's an output.
**Fix:** `depends_on = [module.eks_cluster]`.

### 4. Deprecated add-on argument
**Cause:** `resolve_conflicts` was removed in the EKS module v21 add-on schema.
**Fix:** `resolve_conflicts_on_create` + `resolve_conflicts_on_update = "OVERWRITE"`.

### 5. Jobs never picked up — `runs-on` label mismatch
**Symptom:** "Waiting for a runner…"; `Requested labels: self-hosted`.
**Cause:** `runs-on: [self-hosted, gha-runner-scale-set]`. In the scale-set model a runner has
**only** the scale-set name as a label — there is no `self-hosted` label — so requiring both never
matches.
**Fix:** `runs-on: gha-runner-scale-set` (exactly the scale-set name).

### 6. Local workflow edits had no effect
**Cause:** GitHub runs the workflow from the **pushed commit**, not your working tree.
**Fix:** commit + push the workflow (resolve any merge conflict in favor of `gha-runner-scale-set`).

### 7. Runner registered but never "Listening" — missing container command
**Symptom:** pods churned ~every 30s; controller logged `pod is deleted … failure count` →
backoff; GitHub showed `registered:2, idle:0`; jobs `canceled`.
**Cause:** the values set `template.spec.containers[0].{name,image,resources}`. **Helm replaces
lists wholesale — it does not merge by index.** Supplying a partial `containers[0]` *replaced* the
chart's default container and dropped its `command: ["/home/runner/run.sh"]`. The image has no
default entrypoint that starts the runner, so the pod ran a no-op and exited.
**Fix:** re-supply it: `template.spec.containers[0].command[0] = "/home/runner/run.sh"`.

### 8. Runner connected, then GitHub rejected it — pinned image was deprecated
**Symptom:** logs reached `√ Connected to GitHub` and `Listening for Jobs`, then
`AccessDeniedException: Runner version vX.Y.Z is deprecated and cannot receive messages` (HTTP 403);
pod exited.
**Cause:** the runner image was **pinned to an old tag** (`2.321.0`). GitHub **force-rejects
deprecated runner versions**, and ARC runs runners with `DisableUpdate: true`, so they **cannot
self-update** to recover.
**Fix:** use **`ghcr.io/actions/actions-runner:latest`** (or a regularly bumped current tag).
**Lesson:** never pin the ARC runner image to a stale version.

### 9. Runner pods got the controller's resource limits
**Cause:** copy-paste — runner resources referenced `runner_controller_resources_*` (500m/512Mi)
instead of `runner_deployment_resources_*` (1000m/2Gi).
**Fix:** point the runner container at the deployment locals.

### 10. Hygiene & correctness
- A workflow step ran `kubectl get pods -A`, needing cluster RBAC + kubectl in the image (neither
  present) → **removed** (keeps runners least-privilege).
- `establish_local_connection.sh` used `local` at top level (only valid in a function) → added a
  shebang and removed `local`.
- Removed dead locals/variables and stray debug files; extended `.gitignore`.

### 11. Taint design — don't break DNS at zero-scale
**Context:** tainting the base so runners can't land on on-demand nodes is great for cost — but it
can break the cluster if system pods can't tolerate the taint, *especially* once `minRunners=0`
means the base may be the **only** node group.
**Resolution (verified before applying):** CoreDNS got an explicit `CriticalAddonsOnly` toleration
via add-on `configuration_values`; Karpenter got the toleration **+** `nodeSelector: workload=system`
(so it never self-disrupts); CNI/kube-proxy/pod-identity already carry blanket `Exists` tolerations
(verified with `kubectl`); runner pods intentionally have **no** toleration. (See [3.8](#38-the-taint--toleration-model).)

### 12. Avoided a destroy/recreate of the live base node group
Renaming the node-group map key (`runners` → `system`) would force a **destroy + recreate**,
briefly evicting CoreDNS and Karpenter with nowhere to land mid-apply. The key was **kept as
`runners`** (now the system base) so taint/label/sizing changes apply **in-place**. Rename only in
a maintenance window if desired.

### 13. Spot silently fell back to on-demand — missing service-linked role
**Symptom:** autoscaling worked, but every Karpenter node came up `on-demand` despite the
spot-first NodePool. Karpenter logs:
`UnfulfillableCapacity … AuthFailure.ServiceLinkedRoleCreationNotPermitted: … create the
service-linked role for EC2 Spot Instances`.
**Cause:** the account lacked the **EC2 Spot service-linked role** (`AWSServiceRoleForEC2Spot`),
and Karpenter's role can't create it — so Spot `CreateFleet` failed and Karpenter fell back to
on-demand (which silently *worked*, masking the lost discount).
**Fix:** create it as code — `aws_iam_service_linked_role.spot { aws_service_name = "spot.amazonaws.com" }`.
If it already exists account-wide, `terraform import` it. **Lesson:** "Spot configured" ≠ "Spot
used" — always confirm `capacity-type=spot` on actual nodes.

---

## 13. Troubleshooting matrix

| Symptom | Likely cause | Where to look |
|---|---|---|
| Job stuck "Waiting for a runner" | `runs-on` ≠ scale-set name, or workflow not pushed | Job log "Requested labels"; the pushed workflow |
| Runner pods churn, jobs `canceled` | Missing container command **or** deprecated runner image | `kubectl logs` a runner pod (read past "Listening") |
| `registered>0, idle=0` in listener | Runner not actually listening (image/command) | Runner pod logs; Challenges #7/#8 |
| `Unauthorized` during apply | Static token expiry | `versions.tf` exec auth |
| Chart fails on `githubConfigSecret` | Empty/missing App key | `github.auto.tfvars` loaded? `validate_script.sh` |
| Runner pods stay `Pending` | Karpenter can't provision (discovery tags / limits / capacity) | `kubectl get nodeclaims`; Karpenter logs |
| Nodes are `on-demand` not `spot` | Missing EC2 Spot SLR | Karpenter logs for `ServiceLinkedRoleCreationNotPermitted` |
| Nodes `NotReady` after a taint change | A system pod can't tolerate the taint | DaemonSet / CoreDNS tolerations |
| CoreDNS `Pending` at zero-scale | Missing `CriticalAddonsOnly` toleration | CoreDNS add-on `configuration_values` |
| Karpenter pod won't schedule | `nodeSelector workload=system` but base unlabeled/at capacity | Node labels; base node group sizing |

---

## 14. Security model

- **No secrets in git.** `*.pem`, `*.tfvars`, and Terraform state are git-ignored; the App key and
  `github.auto.tfvars` live only locally. Verify: `git ls-files | grep -iE 'pem|tfvars'` → empty.
- **App key currently passes through Helm values → Terraform state in plaintext.** Hardening:
  pre-create the K8s secret and reference it by name via `githubConfigSecret: <secret-name>`. Treat
  state as sensitive regardless; use an encrypted remote backend.
- **Runner isolation:** runners have **no cluster RBAC**, are **ephemeral** (one job per pod), and
  run on Spot nodes **separate** from system components (taint enforced).
- **IAM least privilege:** Karpenter uses a scoped controller role via Pod Identity; nodes use a
  dedicated node role; SSM is attached for break-glass access.
- **Don't use the account root user** for Terraform — use a scoped IAM role/user.
- **Public API endpoint** is enabled for convenience; restrict with `endpoint_public_access_cidrs`
  (or go private) for production.

---

## 15. Helper scripts

> **Local-only & git-ignored — not committed to the repo** (they can hold account-specific values
> like the AWS account ID). They're optional convenience tools; nothing in the Terraform flow
> depends on them. Recreate them locally if you want them.

- **`establish_local_connection.sh`** — resets stale contexts and writes a fresh kubeconfig
  (`aws eks update-kubeconfig`) aliased to the cluster.
- **`validate_script.sh`** — confirms `github-config-secret` exists in `arc-runners`, all required
  keys are present, the App/installation IDs are numeric, and the private key is a cryptographically
  valid PEM (`openssl rsa -check`).
- **`wtf.sh`** — interactive end-to-end health check: namespaces, controller pod, listener pod,
  runner pods (with logs), recent events, the runner scale set, and a pass/fail summary with
  next-step hints.

---

## 16. FAQ

**Q: Why ephemeral, one-job-per-pod runners?**
Security and reproducibility — no state bleeds between jobs, and a compromised job can't persist.

**Q: Why does `runs-on` use just `gha-runner-scale-set` and not `self-hosted`?**
In the scale-set model the runner's only label *is* the scale-set name. `self-hosted` is a
legacy-model label that these runners don't have. (Challenge #5.)

**Q: Can I run more than 10 concurrent jobs?**
Raise `max_runner_replicas`. Karpenter will provision more nodes up to `karpenter_cpu_limit` (100
vCPU). Mind the cost.

**Q: Will Spot interruptions kill my jobs?**
Possibly — Spot can be reclaimed with a 2-minute warning. Karpenter drains gracefully and the job
will be retried/rescheduled. For interruption-sensitive jobs, set
`karpenter_capacity_types = ["on-demand"]` for that pool, or run them on a separate scale set.

**Q: Why is the Karpenter version not pinned?**
It's resolved dynamically to the latest release (`data.http` + `coalesce`) so you don't drift onto
an unsupported version. Pin via `var.karpenter_version` if you need reproducibility. (Note: the
unauthenticated GitHub API is rate-limited to 60 req/hr — supply a token in CI.)

**Q: How do I add a second, differently-sized runner pool?**
Add another `gha-runner-scale-set` Helm release with a new `runnerScaleSetName` and its own
resources; optionally add a dedicated Karpenter NodePool with matching requirements.

**Q: How much does idle cost?**
Roughly the fixed floor: EKS control plane + single NAT + ~2 base `t3.medium`. Runners and their
nodes cost **$0** when idle.

---

## 17. Glossary

- **ASG** — Auto Scaling Group (the old node-scaling primitive Karpenter replaces).
- **AL2023** — Amazon Linux 2023, the EKS-optimized node AMI family used here.
- **CRD** — Custom Resource Definition (e.g., `NodePool`, `EC2NodeClass`, `AutoscalingRunnerSet`).
- **EC2NodeClass / NodePool** — Karpenter v1 CRDs: the *how* and the *what* of node provisioning.
- **EphemeralRunner / EphemeralRunnerSet / AutoscalingRunnerSet** — ARC CRDs representing a single
  runner, the set the controller scales, and the user-facing scale set, respectively.
- **IRSA** — IAM Roles for Service Accounts (OIDC-based SA→role mapping).
- **JIT config** — just-in-time runner registration payload.
- **Pod Identity** — modern EKS SA→role mapping via the pod-identity agent.
- **SLR** — service-linked role (e.g., `AWSServiceRoleForEC2Spot`).
- **Spot** — discounted, reclaimable EC2 capacity.
- **Taint / Toleration** — node-level pod repulsion and the per-pod opt-in to ignore it.

---

## 18. Future improvements

- **Remote state backend** (S3 + native locking) — required for collaboration; safer than local
  `terraform.tfstate`.
- **Pre-created GitHub App secret** referenced by name — keeps the private key out of TF state.
- **Rename the base node group** `runners` → `system` for clarity (one-time recreate; maintenance
  window).
- **Authenticated GitHub API** for the dynamic Karpenter version lookup in CI (avoid the 60 req/hr
  unauthenticated limit).
- **Per-workload scale sets** (e.g., large-memory or GPU builds) with dedicated NodePools.
- **Private API endpoint** + CIDR allow-lists for the public endpoint.
- **Disruption budgets** on the NodePool to bound consolidation churn during peak hours.
- **Spot-only pool** for fully retryable jobs to squeeze the last ~10–15% of cost.
```
