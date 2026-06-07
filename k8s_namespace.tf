resource "kubernetes_namespace_v1" "namespace_arc_runners" {
  metadata {
    name = "arc-runners"
  }

  depends_on = [
    module.eks_cluster
  ]
}

resource "kubernetes_namespace_v1" "namespace_arc_systems" {
  metadata {
    name = "arc-systems"
  }

  depends_on = [
    module.eks_cluster
  ]
}
