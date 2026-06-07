locals {
  namespace          = coalesce(var.namespace, "runner")
  short_name         = coalesce(var.short_name, "gha-runner")
  cluster_name       = lower(join("-", [local.short_name, "eks"]))
  region             = coalesce(var.region, "ap-south-1")
  availability_zones = coalesce(var.availability_zones, ["ap-south-1a", "ap-south-1b", "ap-south-1c"])
  cidr               = coalesce(var.cidr, "10.0.0.0/16")

  github_owner               = coalesce(var.github_owner, "blue-samarth")
  github_repository          = coalesce(var.github_repository, "blue-samarth/Github_Actions_Runners")
  github_organization        = try(var.github_organization, "")
  github_app_id              = coalesce(var.github_app_id, "123456")
  github_app_installation_id = coalesce(var.github_app_installation_id, "12345678")
  github_app_private_key = (
    var.github_app_private_key != null ? var.github_app_private_key :
    var.github_app_private_key_path != null && fileexists(var.github_app_private_key_path) ? file(var.github_app_private_key_path) :
    try(file("./github-app-private-key.pem"), "")
  )

  runner_controller_resources_limits_cpu      = coalesce(var.runner_controller_resources_limits_cpu, "500m")
  runner_controller_resources_limits_memory   = coalesce(var.runner_controller_resources_limits_memory, "512Mi")
  runner_controller_resources_requests_cpu    = coalesce(var.runner_controller_resources_requests_cpu, "250m")
  runner_controller_resources_requests_memory = coalesce(var.runner_controller_resources_requests_memory, "256Mi")

  runner_image        = coalesce(var.runner_image, "ghcr.io/actions/actions-runner:latest")
  min_runner_replicas = coalesce(var.min_runner_replicas, 1)
  max_runner_replicas = coalesce(var.max_runner_replicas, 5)

  runner_deployment_resources_limits_cpu      = coalesce(var.runner_deployment_resources_limits_cpu, "1000m")
  runner_deployment_resources_limits_memory   = coalesce(var.runner_deployment_resources_limits_memory, "2Gi")
  runner_deployment_resources_requests_cpu    = coalesce(var.runner_deployment_resources_requests_cpu, "500m")
  runner_deployment_resources_requests_memory = coalesce(var.runner_deployment_resources_requests_memory, "1Gi")

  karpenter_version             = coalesce(var.karpenter_version, trimprefix(jsondecode(data.http.karpenter_latest_release.response_body).tag_name, "v"))
  karpenter_namespace           = coalesce(var.karpenter_namespace, "karpenter")
  karpenter_node_instance_types = coalesce(var.karpenter_node_instance_types, ["t3.medium", "t3.large", "t3.xlarge", "t3a.medium", "t3a.large", "t3a.xlarge"])
  karpenter_capacity_types      = coalesce(var.karpenter_capacity_types, ["spot", "on-demand"])
  karpenter_cpu_limit           = coalesce(var.karpenter_cpu_limit, "100")

  system_node_instance_types = coalesce(var.system_node_instance_types, ["t3.medium"])
  system_node_min_size       = coalesce(var.system_node_min_size, 1)
  system_node_desired_size   = coalesce(var.system_node_desired_size, 2)
  system_node_max_size       = coalesce(var.system_node_max_size, 2)
}
