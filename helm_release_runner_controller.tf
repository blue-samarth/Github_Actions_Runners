resource "helm_release" "arc_controller" {
  name             = lower(join("-", [local.short_name, "arc", "controller"]))
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = "0.12.0"
  namespace        = "arc-systems"
  create_namespace = true

  wait    = true
  timeout = 600

  depends_on = [module.eks_cluster]
}

resource "helm_release" "arc_runner_scale_set" {
  name             = lower(join("-", [local.short_name, "scale", "set"]))
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = "0.12.0"
  namespace        = kubernetes_namespace_v1.namespace_arc_runners.metadata[0].name
  create_namespace = false

  set = [
    {
      name  = "githubConfigUrl"
      value = "https://github.com/${local.github_repository}"
    },
    {
      name  = "template.spec.containers[0].name"
      value = "runner"
    },

    {
      name  = "githubConfigSecret.github_app_id"
      value = local.github_app_id
    },
    {
      name  = "githubConfigSecret.github_app_installation_id"
      value = local.github_app_installation_id
    },
    {
      name  = "githubConfigSecret.github_app_private_key"
      value = local.github_app_private_key
    },
    {
      name  = "minRunners"
      value = local.min_runner_replicas
    },

    {
      name  = "maxRunners"
      value = local.max_runner_replicas
    },

    {
      name  = "template.spec.containers[0].image"
      value = local.runner_image
    },

    {
      name  = "template.spec.containers[0].command[0]"
      value = "/home/runner/run.sh"
    },

    {
      name  = "template.spec.containers[0].resources.limits.cpu"
      value = local.runner_deployment_resources_limits_cpu
    },

    {
      name  = "template.spec.containers[0].resources.limits.memory"
      value = local.runner_deployment_resources_limits_memory
    },

    {
      name  = "template.spec.containers[0].resources.requests.cpu"
      value = local.runner_deployment_resources_requests_cpu
    },

    {
      name  = "template.spec.containers[0].resources.requests.memory"
      value = local.runner_deployment_resources_requests_memory
    },
    {
      name  = "controllerServiceAccount.namespace"
      value = "arc-systems"
    },
    {
      name  = "runnerScaleSetName"
      value = lower(join("-", [local.short_name, "scale", "set"]))
    },
    {
      name  = "template.spec.restartPolicy"
      value = "Never"
    },
    {
      name  = "controllerServiceAccount.name"
      value = lower(join("-", [local.short_name, "arc", "controller", "gha-rs-controller"]))
    }
  ]
  wait    = true
  timeout = 600

  depends_on = [
    helm_release.arc_controller,
    kubernetes_namespace_v1.namespace_arc_runners,
    kubernetes_namespace_v1.namespace_arc_systems
  ]
}