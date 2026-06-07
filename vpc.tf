module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">=6.5.0"

  name = lower(join("-", [local.short_name, "vpc"]))
  cidr = local.cidr
  azs  = local.availability_zones

  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnets = [for k, v in local.availability_zones : cidrsubnet(local.cidr, 8, k)]
  public_subnets  = [for k, v in local.availability_zones : cidrsubnet(local.cidr, 8, k + 4)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = { "kubernetes.io/role/elb" = "1"  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = {
    Name  = lower(join("-", [local.short_name, "vpc"]))
    Owner = "Terraform"
    team  = "Devops:blue-samarth"
  }
}
