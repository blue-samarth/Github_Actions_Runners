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

  # Use :latest — GitHub force-rejects deprecated runner versions ("cannot receive
  # messages", HTTP 403), and ARC runs with DisableUpdate=true so the runner can't
  # self-update. A stale pin will break; override var.runner_image only with a CURRENT tag.
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

  # Tiny fixed base node group — hosts only system add-ons + the Karpenter controller.
  # Decoupled from runner counts; GHA runners run on Karpenter spot nodes instead.
  system_node_instance_types = coalesce(var.system_node_instance_types, ["t3.medium"])
  system_node_min_size       = coalesce(var.system_node_min_size, 1)
  system_node_desired_size   = coalesce(var.system_node_desired_size, 2)
  system_node_max_size       = coalesce(var.system_node_max_size, 2)
}

# output "debug_github_app_key_length" {
#   value     = length(local.github_app_private_key)
#   sensitive = false
# }

# output "debug_github_app_key_source" {
#   value = var.github_app_private_key != null ? "from_variable" : (
#     var.github_app_private_key_path != null && fileexists(var.github_app_private_key_path) ? "from_file_path" :
#     fileexists("./github-app-private-key.pem") ? "from_default_path" :
#     "NONE - KEY IS EMPTY!"
#   )
#   sensitive = false
# }