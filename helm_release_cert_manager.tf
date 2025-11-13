resource "helm_release" "cert_manager" {
  name             = lower(join("-", [local.short_name, "cert", "manager"]))
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.13.3"
  namespace        = kubernetes_namespace_v1.namespace_arc_runners.metadata[0].name
  create_namespace = false

  # Helm provider v3.x syntax for set values
  set = [
    {
      name  = "installCRDs"
      value = "true"
    },
    {
      name  = "prometheus.enabled"
      value = "false"
    },
    {
      name  = "resources.limits.cpu"
      value = "100m"
    },
    {
      name  = "resources.limits.memory"
      value = "128Mi"
    },
    {
      name  = "resources.requests.cpu"
      value = "50m"
    },
    {
      name  = "resources.requests.memory"
      value = "64Mi"
    }
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  depends_on = [
    kubernetes_namespace_v1.namespace_arc_runners,
    module.eks_cluster
  ]
}