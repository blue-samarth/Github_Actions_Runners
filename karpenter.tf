# Resolve the latest Karpenter release at plan time (see local.karpenter_version).
data "http" "karpenter_latest_release" {
  url = "https://api.github.com/repos/aws/karpenter-provider-aws/releases/latest"
  request_headers = {
    Accept = "application/vnd.github+json"
  }
}

# Controller IAM role (Pod Identity), node IAM role + instance profile, and the
# SQS interruption queue with its EventBridge rules.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.8.0"

  cluster_name = module.eks_cluster.cluster_name
  namespace    = local.karpenter_namespace

  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    SSMCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Name  = lower(join("-", [local.short_name, "karpenter"]))
    Owner = "Terraform"
    team  = "Devops:blue-samarth"
  }
}

# CRDs are managed by the dedicated chart so they upgrade cleanly with the controller.
resource "helm_release" "karpenter_crd" {
  name             = lower(join("-", [local.short_name, "karpenter", "crd"]))
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = local.karpenter_version
  namespace        = local.karpenter_namespace
  create_namespace = true

  wait    = true
  timeout = 600

  depends_on = [module.eks_cluster]
}

resource "helm_release" "karpenter" {
  name             = lower(join("-", [local.short_name, "karpenter"]))
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = local.karpenter_version
  namespace        = local.karpenter_namespace
  create_namespace = false

  set = [
    {
      name  = "settings.clusterName"
      value = module.eks_cluster.cluster_name
    },
    {
      name  = "settings.interruptionQueue"
      value = module.karpenter.queue_name
    },
    {
      name  = "serviceAccount.name"
      value = module.karpenter.service_account
    },
    {
      name  = "controller.resources.requests.cpu"
      value = "250m"
    },
    {
      name  = "controller.resources.requests.memory"
      value = "256Mi"
    },
    {
      name  = "controller.resources.limits.cpu"
      value = "500m"
    },
    {
      name  = "controller.resources.limits.memory"
      value = "512Mi"
    },
    # Pin the controller to the base node group and tolerate its taint so Karpenter
    # never runs on (and can't consolidate) a node it manages.
    {
      name  = "nodeSelector.workload"
      value = "system"
    },
    {
      name  = "tolerations[0].key"
      value = "CriticalAddonsOnly"
    },
    {
      name  = "tolerations[0].operator"
      value = "Exists"
    }
  ]

  wait    = true
  timeout = 600

  depends_on = [
    module.karpenter,
    helm_release.karpenter_crd
  ]
}

# Defines how Karpenter launches EC2 nodes (AMI, role, subnet/SG discovery).
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      role = module.karpenter.node_iam_role_name
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = local.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = local.cluster_name } }
      ]
      tags = {
        Name  = lower(join("-", [local.short_name, "karpenter", "node"]))
        Owner = "Terraform"
        team  = "Devops:blue-samarth"
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

# Constrains what Karpenter may provision and when it consolidates.
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = local.karpenter_capacity_types
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = local.karpenter_node_instance_types
            }
          ]
        }
      }
      limits = {
        cpu = local.karpenter_cpu_limit
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}
