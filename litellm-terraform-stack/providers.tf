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

provider "kubernetes" {
  host                   = local.platform == "EKS" ? module.eks_cluster[0].cluster_endpoint : ""
  cluster_ca_certificate = local.platform == "EKS" ? base64decode(module.eks_cluster[0].cluster_ca) : ""
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.platform == "EKS" ? ["eks", "get-token", "--cluster-name", module.eks_cluster[0].cluster_name] : []
  }
}

provider "helm" {
  kubernetes {
    host                   = local.platform == "EKS" ? module.eks_cluster[0].cluster_endpoint : ""
    cluster_ca_certificate = local.platform == "EKS" ? base64decode(module.eks_cluster[0].cluster_ca) : ""
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.platform == "EKS" ? ["eks", "get-token", "--cluster-name", module.eks_cluster[0].cluster_name] : []
    }
  }
}



# provider "kubernetes" {
#   host                   = module.eks_cluster[0].cluster_endpoint
#   cluster_ca_certificate = base64decode(module.eks_cluster[0].cluster_ca)
#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args        = ["eks", "get-token", "--cluster-name", module.eks_cluster[0].cluster_name]
#   }
# }

# provider "helm" {
#   kubernetes {
#     host                   = module.eks_cluster[0].cluster_endpoint
#     cluster_ca_certificate = base64decode(module.eks_cluster[0].cluster_ca)
#     exec {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       command     = "aws"
#       args        = ["eks", "get-token", "--cluster-name", module.eks_cluster[0].cluster_name]
#     }
#   }
# }