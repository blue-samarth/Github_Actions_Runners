# Create Kubernetes secret for GitHub App authentication
resource "kubernetes_secret_v1" "github_app_credentials" {
  metadata {
    name      = "controller-manager"
    namespace = kubernetes_namespace_v1.namespace_arc_runners.metadata[0].name

    labels = {
      managed-by = "terraform"
      purpose    = "github-app-auth"
    }
  }

  data = {
    github_app_id              = local.github_app_id
    github_app_installation_id = local.github_app_installation_id
    github_app_private_key     = local.github_app_private_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.namespace_arc_runners]
}