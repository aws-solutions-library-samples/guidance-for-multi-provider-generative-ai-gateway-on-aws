data "aws_eks_cluster" "existing" {
  name  = var.existing_cluster_name
}

resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  # Wait until the cluster and its endpoint are actually ready
  depends_on = [
    data.aws_eks_cluster.existing
  ]

  # The 'data' block is YAML that instructs EKS how to map IAM roles to Kubernetes RBAC
  data = {
    # Map IAM roles for the Node Group
    mapRoles = <<-YAML
      - rolearn: arn:aws:iam::235614385815:role/Admin
        username: system:admin
        groups:
          - system:masters
    YAML
  }
}

locals {
  cluster_endpoint = data.aws_eks_cluster.existing.endpoint
  cluster_ca = data.aws_eks_cluster.existing.certificate_authority[0].data
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.existing_cluster_name]
  }
}