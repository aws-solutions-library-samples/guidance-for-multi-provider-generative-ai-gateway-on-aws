################################################################################
# Base
################################################################################
provider "aws" {}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

locals {
  region = coalesce(var.region, data.aws_region.current.name)

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    AWSSolution = "ToDo"
    GithubRepo  = "https://github.com/aws-solutions-library-samples/"
  }
}

################################################################################
# IAM Roles
################################################################################

data "aws_iam_policy_document" "assume_role" {

  statement {
    sid     = "AssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "eks_developers" {
  name               = "${var.name}-developers"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role" "eks_operators" {
  name               = "${var.name}-operators"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}
#--------------------------------------------------------------
# Adding guidance solution ID via AWS CloudFormation resource
#--------------------------------------------------------------
resource "aws_cloudformation_stack" "guidance_deployment_metrics" {
    name = "tracking-stack"
    template_body = <<STACK
    {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Description": "Guidance for GenAI Gateway running on Amazon EKS",
        "Resources": {
            "EmptyResource": {
                "Type": "AWS::CloudFormation::WaitConditionHandle"
            }
        }
    }
    STACK
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
  }
}

# Kubernetes Secrets
resource "kubernetes_secret" "litellm_api_keys" {
  metadata {
    name = "litellm-api-keys"
  }

  data = {
    DATABASE_URL           = var.database_url
    LITELLM_MASTER_KEY    = var.litellm_master_key
    LITELLM_SALT_KEY      = var.litellm_salt_key
    OPENAI_API_KEY        = var.openai_api_key
    AZURE_OPENAI_API_KEY  = var.azure_openai_api_key
    AZURE_API_KEY         = var.azure_api_key
    ANTHROPIC_API_KEY     = var.anthropic_api_key
    GROQ_API_KEY          = var.groq_api_key
    COHERE_API_KEY        = var.cohere_api_key
    CO_API_KEY            = var.co_api_key
    HF_TOKEN              = var.hf_token
    HUGGINGFACE_API_KEY   = var.huggingface_api_key
    DATABRICKS_API_KEY    = var.databricks_api_key
    GEMINI_API_KEY        = var.gemini_api_key
    CODESTRAL_API_KEY     = var.codestral_api_key
    MISTRAL_API_KEY       = var.mistral_api_key
    AZURE_AI_API_KEY      = var.azure_ai_api_key
    NVIDIA_NIM_API_KEY    = var.nvidia_nim_api_key
    XAI_API_KEY           = var.xai_api_key
    PERPLEXITYAI_API_KEY  = var.perplexityai_api_key
    GITHUB_API_KEY        = var.github_api_key
    DEEPSEEK_API_KEY      = var.deepseek_api_key
    AI21_API_KEY          = var.ai21_api_key
    LANGSMITH_API_KEY     = var.langsmith_api_key
  }
}

resource "kubernetes_secret" "middleware_secrets" {
  metadata {
    name = "middleware-secrets"
  }

  data = {
    DATABASE_MIDDLEWARE_URL = var.database_middleware_url
    MASTER_KEY             = var.litellm_master_key
  }
}

# Deployment
resource "kubernetes_deployment" "litellm" {
  metadata {
    name = "litellm-deployment"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "litellm"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm"
        }
      }

      spec {
        node_selector = {
          "eks.amazonaws.com/nodegroup" = aws_eks_node_group.core_nodegroup.node_group_name
        }
        container {
          name  = "litellm-container"
          image = "${var.ecr_litellm_repository_url}:${var.litellm_version}"

          port {
            container_port = 4000
          }

          env {
            name  = "LITELLM_CONFIG_BUCKET_NAME"
            value = var.config_bucket_name
          }

          env {
            name  = "LITELLM_CONFIG_BUCKET_OBJECT_KEY"
            value = "config.yaml"
          }

          env {
            name  = "UI_USERNAME"
            value = "admin"
          }

          env {
            name  = "REDIS_URL"
            value = var.redis_url
          }

          env {
            name  = "LANGSMITH_PROJECT"
            value = var.langsmith_project
          }

          env {
            name  = "LANGSMITH_DEFAULT_RUN_NAME"
            value = var.langsmith_default_run_name
          }

          env {
            name  = "AWS_REGION"
            value = var.region
          }

          env {
            name = "LITELLM_LOG"
            value = "DEBUG"
          }

          env {
            name = "LITELLM_LOCAL_MODEL_COST_MAP"
            value = var.disable_outbound_network_access ? "True" : "False"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.litellm_api_keys.metadata[0].name
            }
          }

          readiness_probe {
            http_get {
              path = "/health/liveliness"
              port = 4000
            }
            initial_delay_seconds = 20
            period_seconds       = 10
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = 4000
            }
            initial_delay_seconds = 20
            period_seconds       = 10
          }
        }

        container {
          name  = "middleware-container"
          image = "${var.ecr_middleware_repository_url}:latest"

          port {
            container_port = 3000
          }

          env {
            name  = "OKTA_ISSUER"
            value = var.okta_issuer
          }

          env {
            name  = "OKTA_AUDIENCE"
            value = var.okta_audience
          }

          env {
            name  = "AWS_REGION"
            value = var.region
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = var.region
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.middleware_secrets.metadata[0].name
            }
          }

          readiness_probe {
            http_get {
              path = "/bedrock/health/liveliness"
              port = 3000
            }
            initial_delay_seconds = 20
            period_seconds       = 10
          }

          liveness_probe {
            http_get {
              path = "/bedrock/health/liveliness"
              port = 3000
            }
            initial_delay_seconds = 20
            period_seconds       = 10
          }
        }
      }
    }
  }
  depends_on = [aws_eks_node_group.core_nodegroup]
}

# Ingress
resource "kubernetes_ingress_v1" "litellm" {
  wait_for_load_balancer = true
  metadata {
    name = "litellm-ingress"
    annotations = {
      "kubernetes.io/ingress.class"                = "alb"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{"HTTP" = 80}, {"HTTPS" = 443}])
      "alb.ingress.kubernetes.io/certificate-arn"  = var.certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-2016-08"
      "alb.ingress.kubernetes.io/wafv2-acl-arn"   = var.wafv2_acl_arn
    }
  }

  spec {
    rule {
      host = var.domain_name
      http {
        path {
          path      = "/bedrock/model"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/v1/chat/completions"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/chat/completions"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/chat-history"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/bedrock/chat-history"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/bedrock/health/liveliness"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/session-ids"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/key/generate"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/user/new"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port3000"
              }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.litellm.metadata[0].name
              port {
                name = "port4000"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.aws_load_balancer_controller, module.aws_load_balancer_controller_irsa_role, aws_eks_addon.coredns, aws_eks_node_group.core_nodegroup]
}

# Service
resource "kubernetes_service" "litellm" {
  metadata {
    name = "litellm-service"
  }

  spec {
    selector = {
      app = "litellm"
    }

    port {
      name        = "port4000"
      port        = 4000
      target_port = 4000
    }

    port {
      name        = "port3000"
      port        = 3000
      target_port = 3000
    }

    type = "ClusterIP"
  }
}

# Add AWS Load Balancer Controller
module "aws_load_balancer_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${var.name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = aws_iam_openid_connect_provider.this.arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.11.0"

  set {
    name  = "clusterName"
    value = local.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_load_balancer_controller_irsa_role.iam_role_arn
  }

  //Only need to set to internal ECR repo when internet access not available
  dynamic "set" {
    for_each = var.disable_outbound_network_access ? [1] : []
    content {
      name  = "image.repository"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/my-public-ecr-cache-repo/eks/aws-load-balancer-controller"
    }
  }

  # set {
  #   name  = "image.repository"
  #   value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/my-public-ecr-cache-repo/eks/aws-load-balancer-controller"
  # }

  set {
    name  = "enableShield"
    value = "false"
  }

  set {
    name  = "enableWaf"
    value = "false"
  }

  set {
    name  = "enableWafv2"
    value = "true"
  }

  depends_on = [
    aws_eks_node_group.core_nodegroup,
    module.aws_load_balancer_controller_irsa_role
  ]
}

# Add additional IAM policies to node groups
resource "aws_iam_role_policy" "node_additional_policies" {
  name = "${var.name}-eks-node-additional"
  role = aws_iam_role.eks_nodegroup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.config_bucket_arn,
          "${var.config_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = [
          var.log_bucket_arn,
          "${var.log_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:*"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# Get the ALB details using data source
data "aws_lb" "ingress_alb" {
  # The ALB name will be based on the cluster name and ingress name
  # We need to wait for the ingress to create the ALB first
  depends_on = [kubernetes_ingress_v1.litellm]
  
  tags = {
    # The ALB created by the AWS Load Balancer Controller will have this tag
    "elbv2.k8s.aws/cluster" = local.cluster_name
    # This tag helps identify the specific ingress
    "ingress.k8s.aws/stack" = "default/litellm-ingress"
  }
}

# Add provider configurations
provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    }
  }
}