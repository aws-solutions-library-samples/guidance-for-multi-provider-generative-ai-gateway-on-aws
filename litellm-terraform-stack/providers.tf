terraform {
  backend "s3" {}
  required_providers {
      helm = {
        source  = "hashicorp/helm"
        version = "~> 2.0"
      }
    }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  SolutionNameKeySatisfyingRestrictions = "Guidance-for-Running-Generative-AI-Gateway-Proxy-on-AWS"
  common_labels = {
    project     = "llmgateway"
    AWSSolution = "ToDo"
    GithubRepo  = "https://github.com/aws-solutions-library-samples/"
    SolutionID  = "SO9022"
    SolutionNameKey = "Guidance for Running Generative AI Gateway Proxy on AWS"
    SolutionVersionKey = "1.0.0"
  }
}


provider "aws" {
  default_tags {
    tags = local.common_labels
  }
}

# NOTE: AWS Service Catalog AppRegistry entered maintenance mode on July 30, 2026
# and rejects CreateApplication for accounts that have not previously used it
# (AccessDeniedException / 403). This resource was tracking-only (it grouped and
# tagged solution resources for inventory) and had no functional role, so it has
# been removed to allow deployment to proceed. The solution's resources are still
# tagged via the provider default_tags above.
# See: https://docs.aws.amazon.com/servicecatalog/latest/arguide/app-registry-availability-change.html

data "aws_eks_cluster_auth" "cluster" {
  count = local.platform == "EKS" ? 1 : 0
  name = module.eks_cluster[0].cluster_name
}

provider "kubernetes" {
  host                   = local.platform == "EKS" ? module.eks_cluster[0].cluster_endpoint : ""
  cluster_ca_certificate = local.platform == "EKS" ? base64decode(module.eks_cluster[0].cluster_ca) : ""
  token = local.platform == "EKS" ? data.aws_eks_cluster_auth.cluster[0].token : ""
}

provider "helm" {
  kubernetes {
    host                   = local.platform == "EKS" ? module.eks_cluster[0].cluster_endpoint : ""
    cluster_ca_certificate = local.platform == "EKS" ? base64decode(module.eks_cluster[0].cluster_ca) : ""
    token = local.platform == "EKS" ? data.aws_eks_cluster_auth.cluster[0].token : ""
  }
}
