terraform {
  backend "s3" {}
}

locals {
  common_labels = {
    project     = "llmgateway"
    AWSSolution = "ToDo"
    GithubRepo  = "https://github.com/aws-solutions-library-samples/"
  }
}


provider "aws" {
  default_tags {
    tags = local.common_labels
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
