terraform {
  backend "s3" {}
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

resource "aws_servicecatalogappregistry_application" "solution_application" {
  name        = "${local.SolutionNameKeySatisfyingRestrictions}-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Service Catalog application to track and manage all your resources for the solution ${local.common_labels.SolutionNameKey}"

  tags = {
    "Solutions:SolutionID"      = local.common_labels.SolutionID
    "Solutions:SolutionName"    = local.common_labels.SolutionNameKey
    "Solutions:SolutionVersion" = local.common_labels.SolutionVersionKey
    "Solutions:ApplicationType" = "AWS-Solutions"
  }
}



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
