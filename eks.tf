data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

module "eks_cluster" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0"

  name               = lower(join("-", [local.short_name, "eks"]))
  kubernetes_version = "1.33"

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true
  enable_irsa                              = true

  addons = {
    coredns = {
      before_compute    = true
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute    = true
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    runners = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = local.min_runner_replicas
      max_size     = local.max_runner_replicas
      desired_size = local.desired_size_runner_replicas

      update_config = {
        max_unavailable_percentage = 33
      }

      iam_role_additional_policies = {
        SSMCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  tags = {
    Name  = lower(join("-", [local.short_name, "eks"]))
    Owner = "Terraform"
    team  = "Devops:blue-samarth"
  }
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks_cluster.cluster_name
}