################################################################################
# Base
################################################################################
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# Kubernetes Secrets
# Add a sleep to allow RBAC permissions to propagate
resource "time_sleep" "wait_for_rbac_propagation_before_creating_secrets" {
  depends_on = [
    aws_eks_access_entry.admin,
    aws_eks_access_policy_association.admin_policy
  ]
  create_duration = "5s"
}

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
    LANGFUSE_SECRET_KEY = var.langfuse_secret_key
  }

  depends_on = [
    time_sleep.wait_for_rbac_propagation_before_creating_secrets,
    aws_eks_access_entry.developers,
    aws_eks_access_entry.operators
  ]
}

resource "kubernetes_secret" "middleware_secrets" {
  metadata {
    name = "middleware-secrets"
  }

  data = {
    DATABASE_MIDDLEWARE_URL = var.database_url
    MASTER_KEY             = var.litellm_master_key
  }

  depends_on = [
    time_sleep.wait_for_rbac_propagation_before_creating_secrets,
    aws_eks_access_entry.developers,
    aws_eks_access_entry.operators
  ]
}

# Deployment
resource "kubernetes_deployment" "litellm" {
  metadata {
    name = "litellm-deployment"
  }

  spec {
    replicas = var.desired_capacity

    selector {
      match_labels = {
        app = "litellm"
      }
    }

    template {
      metadata {
        labels = merge(
          { app = "litellm" },
        )
      }

      spec {
        node_selector = {
          "eks.amazonaws.com/nodegroup" = aws_eks_node_group.core_nodegroup.node_group_name
        }
        container {
          name  = "litellm-container"
          image = "${var.ecr_litellm_repository_url}:${var.litellm_version}"
          image_pull_policy = "Always"

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
            name  = "REDIS_HOST"
            value = var.redis_host
          }

          env {
            name  = "REDIS_PORT"
            value = var.redis_port
          }

          env {
            name  = "REDIS_PASSWORD"
            value = var.redis_password
          }

          env {
            name  = "REDIS_SSL"
            value = "True"
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
            value = data.aws_region.current.name
          }

          env {
            name = "LITELLM_LOG"
            value = "DEBUG"
          }

          env {
            name = "LITELLM_LOCAL_MODEL_COST_MAP"
            value = var.disable_outbound_network_access ? "True" : "False"
          }

          env {
            name = "NO_DOCS"
            value = var.disable_swagger_page ? "True" : "False"
          }

          env {
            name = "DISABLE_ADMIN_UI"
            value = var.disable_admin_ui ? "True" : "False"
          }

          env {
            name = "LANGFUSE_PUBLIC_KEY"
            value = var.langfuse_public_key
          }

          env {
            name = "LANGFUSE_HOST"
            value = var.langfuse_host
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
            value = data.aws_region.current.name
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = data.aws_region.current.name
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
      "alb.ingress.kubernetes.io/scheme"           = var.public_load_balancer ? "internet-facing" : "internal"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{"HTTP" = 80}, {"HTTPS" = 443}])
      "alb.ingress.kubernetes.io/certificate-arn"  = var.certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-2016-08"
      "alb.ingress.kubernetes.io/wafv2-acl-arn"   = var.wafv2_acl_arn
    }
  }

  spec {
    rule {
      host = var.record_name
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
  depends_on = [helm_release.aws_load_balancer_controller, module.aws_load_balancer_controller_irsa_role, aws_eks_addon.coredns, aws_eks_node_group.core_nodegroup, aws_eks_access_entry.admin, aws_eks_access_policy_association.admin_policy]
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

  depends_on = [
    aws_eks_access_entry.admin,
    aws_eks_access_policy_association.admin_policy,
    aws_eks_access_entry.developers,
    aws_eks_access_entry.operators,
    aws_eks_node_group.core_nodegroup
  ]
}

# Add AWS Load Balancer Controller
module "aws_load_balancer_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.52.2"

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

  set {
    name  = "podSecurityContext.runAsNonRoot"
    value = "true"
  }

  set {
    name  = "podSecurityContext.runAsUser"
    value = "1000"
  }

  set {
    name  = "podSecurityContext.runAsGroup"
    value = "1000"
  }

  //Only need to set to internal ECR repo when internet access not available
  dynamic "set" {
    for_each = var.disable_outbound_network_access ? [1] : []
    content {
      name  = "image.repository"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${var.eks_alb_controller_private_ecr_repository_name}/eks/aws-load-balancer-controller"
    }
  }

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
    module.aws_load_balancer_controller_irsa_role,
    aws_eks_access_entry.admin,
    aws_eks_access_policy_association.admin_policy
  ]
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