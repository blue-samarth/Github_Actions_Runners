variable "namespace" { default = null }
variable "github_owner" { default = null }
variable "github_repository" { default = null }
variable "github_organization" { default = null }
variable "min_runner_replicas" { default = null }
variable "max_runner_replicas" { default = null }
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

variable "runner_controller_resources_limits_cpu" { default = null }
variable "runner_controller_resources_limits_memory" { default = null }
variable "runner_controller_resources_requests_cpu" { default = null }
variable "runner_controller_resources_requests_memory" { default = null }

variable "runner_deployment_resources_limits_cpu" { default = null }
variable "runner_deployment_resources_limits_memory" { default = null }
variable "runner_deployment_resources_requests_cpu" { default = null }
variable "runner_deployment_resources_requests_memory" { default = null }

variable "karpenter_version" { default = null }
variable "karpenter_namespace" { default = null }
variable "karpenter_node_instance_types" { default = null }
variable "karpenter_capacity_types" { default = null }
variable "karpenter_cpu_limit" { default = null }

variable "system_node_instance_types" { default = null }
variable "system_node_min_size" { default = null }
variable "system_node_desired_size" { default = null }
variable "system_node_max_size" { default = null }
