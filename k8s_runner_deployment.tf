resource "kubectl_manifest" "runner_deployment" {
  yaml_body = yamlencode({
    apiVersion = "actions.summerwind.dev/v1alpha1"
    kind       = "RunnerDeployment"
    metadata = {
      name      = lower(join("-", [local.short_name, "runner", "deployment"]))
      namespace = kubernetes_namespace_v1.namespace_arc_runners.metadata[0].name
    }
    spec = merge(
      {
        replicas = local.max_runner_replicas
        template = {
          metadata = {
            labels = {
              app = local.short_name
            }
          }
          spec = {
            image         = local.runner_image
            containerMode = "dind"
            ephemeral     = true
            resources = {
              limits = {
                cpu    = local.runner_deployment_resources_limits_cpu
                memory = local.runner_deployment_resources_limits_memory
              }
              requests = {
                cpu    = local.runner_deployment_resources_requests_cpu
                memory = local.runner_deployment_resources_requests_memory
              }
            }
            labels = local.runner_labels
          }
        }
      },
      local.github_repository != "" ? { repository = local.github_repository } : {},
      local.github_organization != "" ? { organization = local.github_organization } : {}
    )
  })

  depends_on = [helm_release.actions_runner_controller]
}


resource "kubectl_manifest" "runner_autoscaler" {
  yaml_body = yamlencode({
    apiVersion = "actions.summerwind.dev/v1alpha1"
    kind       = "HorizontalRunnerAutoscaler"
    metadata = {
      name      = lower(join("-", [local.short_name, "runner", "autoscaler"]))
      namespace = kubernetes_namespace_v1.namespace_arc_runners.metadata[0].name
    }
    spec = {
      scaleTargetRef = {
        name = lower(join("-", [local.short_name, "runner", "deployment"]))
      }
      minReplicas = local.min_runner_replicas
      maxReplicas = local.max_runner_replicas
      metrics = [
        {
          type               = "PercentageRunnersBusy"
          scaleUpThreshold   = local.runner_autoscaler_scale_up_threshold
          scaleDownThreshold = local.runner_autoscaler_scale_down_threshold
          scaleUpFactor      = local.runner_autoscaler_scale_up_factor
          scaleDownFactor    = local.runner_autoscaler_scale_down_factor
        }
      ]
    }
  })

  depends_on = [kubectl_manifest.runner_deployment]
}