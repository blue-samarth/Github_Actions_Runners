data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

module "eks_cluster" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0"

  name               = local.cluster_name
  kubernetes_version = "1.36"

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true
  enable_irsa                              = true

  addons = {
    coredns = {
      before_compute              = true
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      # Tolerate the system-node taint so CoreDNS can run on the base group
      # (critical when runners scale to zero and no Karpenter nodes exist).
      configuration_values = jsonencode({
        tolerations = [
          { key = "CriticalAddonsOnly", operator = "Exists" }
        ]
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute              = true
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  node_security_group_tags = { "karpenter.sh/discovery" = local.cluster_name }

  # Base/system node group. Tainted CriticalAddonsOnly so GHA runners never land
  # here — they run on Karpenter spot nodes. Sized independently of runner counts.
  # Key kept as "runners" to avoid a destroy/recreate of the live base node group.
  eks_managed_node_groups = {
    runners = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = local.system_node_instance_types

      min_size     = local.system_node_min_size
      max_size     = local.system_node_max_size
      desired_size = local.system_node_desired_size

      labels = {
        workload = "system"
      }

      taints = {
        system = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        SSMCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  tags = {
    Name  = local.cluster_name
    Owner = "Terraform"
    team  = "Devops:blue-samarth"
  }
}
