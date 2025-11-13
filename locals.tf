locals {
  namespace          = coalesce(var.namespace, "runner")
  short_name         = coalesce(var.short_name, "gha-runner")
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

  Sync_period_in_minutes = coalesce(var.Sync_period_in_minutes, "1m")

  runner_controller_resources_limits_cpu      = coalesce(var.runner_controller_resources_limits_cpu, "500m")
  runner_controller_resources_limits_memory   = coalesce(var.runner_controller_resources_limits_memory, "512Mi")
  runner_controller_resources_requests_cpu    = coalesce(var.runner_controller_resources_requests_cpu, "250m")
  runner_controller_resources_requests_memory = coalesce(var.runner_controller_resources_requests_memory, "256Mi")

  runner_image                 = coalesce(var.runner_image, "myoung34/github-runner:latest")
  runner_labels                = coalesce(var.runner_labels, ["self-hosted", "linux", "x64", "k8s"])
  min_runner_replicas          = coalesce(var.min_runner_replicas, 1)
  max_runner_replicas          = coalesce(var.max_runner_replicas, 10)
  desired_size_runner_replicas = coalesce(var.desired_size_runner_replicas, 2)

  runner_deployment_resources_limits_cpu      = coalesce(var.runner_deployment_resources_limits_cpu, "1000m")
  runner_deployment_resources_limits_memory   = coalesce(var.runner_deployment_resources_limits_memory, "1024Mi")
  runner_deployment_resources_requests_cpu    = coalesce(var.runner_deployment_resources_requests_cpu, "500m")
  runner_deployment_resources_requests_memory = coalesce(var.runner_deployment_resources_requests_memory, "512Mi")

  runner_autoscaler_scale_up_threshold   = coalesce(var.runner_autoscaler_scale_up_threshold, "0.75")
  runner_autoscaler_scale_down_threshold = coalesce(var.runner_autoscaler_scale_down_threshold, "0.25")
  runner_autoscaler_scale_up_factor      = coalesce(var.runner_autoscaler_scale_up_factor, "2")
  runner_autoscaler_scale_down_factor    = coalesce(var.runner_autoscaler_scale_down_factor, "0.5")
}
