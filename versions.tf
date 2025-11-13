terraform {
  required_version = ">=1.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=6.0.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">=2.30.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = ">=3.0.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">=1.14.0"
    }
  }
}

provider "aws" { region = local.region }

provider "helm" {
  kubernetes = {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data) # Fixed
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data) # Fixed
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "kubectl" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}