variable "namespace" { default = null }
variable "github_owner" { default = null }
variable "github_repository" { default = null }
variable "github_organization" { default = null }
variable "min_runner_replicas" { default = null }
variable "max_runner_replicas" { default = null }
variable "desired_size_runner_replicas" { default = null }
variable "runner_labels" { default = null }
variable "runner_image" { default = null }
variable "region" { default = null }
variable "cidr" { default = null }
variable "availability_zones" { default = null }
variable "short_name" { default = null }
variable "github_app_id" { default = null }
variable "github_app_installation_id" { default = null }
variable "github_app_private_key" {
  default   = null
  sensitive = true
}
variable "github_app_private_key_path" { default = null }
variable "Sync_period_in_minutes" { default = null }

variable "runner_controller_resources_limits_cpu" { default = null }
variable "runner_controller_resources_limits_memory" { default = null }
variable "runner_controller_resources_requests_cpu" { default = null }
variable "runner_controller_resources_requests_memory" { default = null }

variable "runner_deployment_resources_limits_cpu" { default = null }
variable "runner_deployment_resources_limits_memory" { default = null }
variable "runner_deployment_resources_requests_cpu" { default = null }
variable "runner_deployment_resources_requests_memory" { default = null }

variable "runner_autoscaler_scale_up_threshold" { default = null }
variable "runner_autoscaler_scale_down_threshold" { default = null }
variable "runner_autoscaler_scale_up_factor" { default = null }
variable "runner_autoscaler_scale_down_factor" { default = null }
