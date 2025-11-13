# Install Actions Runner Controller in arc-runners namespace
resource "helm_release" "actions_runner_controller" {
  name             = lower(join("-", [local.short_name, "actions", "runner", "controller"]))
  repository       = "https://actions-runner-controller.github.io/actions-runner-controller"
  chart            = "actions-runner-controller"
  version          = "0.23.7"
  namespace        = kubernetes_namespace_v1.namespace_arc_runners.metadata[0].name
  create_namespace = false

  set = [
    {
      name  = "syncPeriod"
      value = local.Sync_period_in_minutes
    },
    {
      name  = "authSecret.enabled"
      value = "true"
    },
    {
      name  = "authSecret.name"
      value = kubernetes_secret_v1.github_app_credentials.metadata[0].name
    },
    {
      name  = "githubAppID"
      value = local.github_app_id
    },
    {
      name  = "githubAppInstallationID"
      value = local.github_app_installation_id
    },
    {
      name  = "resources.limits.cpu"
      value = local.runner_controller_resources_limits_cpu
    },
    {
      name  = "resources.limits.memory"
      value = local.runner_controller_resources_limits_memory
    },
    {
      name  = "resources.requests.cpu"
      value = local.runner_controller_resources_requests_cpu
    },
    {
      name  = "resources.requests.memory"
      value = local.runner_controller_resources_requests_memory
    }
  ]

  # Wait for deployment to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  depends_on = [
    kubernetes_secret_v1.github_app_credentials,
    helm_release.cert_manager
  ]
}