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

    http = {
      source  = "hashicorp/http"
      version = ">=3.0.0"
    }
  }
}

provider "aws" { region = local.region }

provider "helm" {
  kubernetes = {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", local.region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", local.region]
  }
}

provider "kubectl" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", local.region]
  }
}