data "aws_region" "current" {}

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "litellm" {
  family                   = "${var.name}-fargate-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.vcpus * 1024
  memory                   = var.vcpus * 1024 * 2
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture == "x86" ? "X86_64" : "ARM64"
  }

  container_definitions = <<DEFINITION
[
  {
    "name": "LiteLLMContainer",
    "image": "${var.ecr_litellm_repository_url}:${var.litellm_version}",
    "essential": true,
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${var.name}-litellm",
        "awslogs-region": "${data.aws_region.current.name}",
        "awslogs-stream-prefix": "LiteLLM"
      }
    },
    "environment": [
      { "name": "LITELLM_LOG", "value": "DEBUG" },
      { "name": "LITELLM_CONFIG_BUCKET_NAME", "value": "${var.config_bucket_name}" },
      { "name": "LITELLM_CONFIG_BUCKET_OBJECT_KEY", "value": "config.yaml" },
      { "name": "UI_USERNAME", "value": "admin" },
      { "name": "REDIS_URL", "value": "${var.redis_url}" },
      { "name": "LANGSMITH_PROJECT", "value": "${var.langsmith_project}" },
      { "name": "LANGSMITH_DEFAULT_RUN_NAME", "value": "${var.langsmith_default_run_name}" },
      { "name": "LITELLM_LOCAL_MODEL_COST_MAP", "value": "${var.disable_outbound_network_access ? "True" : "False"}" }
    ],
    "secrets": [
      {
        "name": "DATABASE_URL",
        "valueFrom": "${var.main_db_secret_arn}"
      },
      {
        "name": "LITELLM_MASTER_KEY",
        "valueFrom": "${var.master_and_salt_key_secret_arn}:LITELLM_MASTER_KEY::"
      },
      {
        "name": "UI_PASSWORD",
        "valueFrom": "${var.master_and_salt_key_secret_arn}:LITELLM_MASTER_KEY::"
      },
      {
        "name": "LITELLM_SALT_KEY",
        "valueFrom": "${var.master_and_salt_key_secret_arn}:LITELLM_SALT_KEY::"
      },
      {
        "name": "OPENAI_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:OPENAI_API_KEY::"
      },
      {
        "name": "AZURE_OPENAI_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:AZURE_OPENAI_API_KEY::"
      },
      {
        "name": "AZURE_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:AZURE_API_KEY::"
      },
      {
        "name": "ANTHROPIC_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:ANTHROPIC_API_KEY::"
      },
      {
        "name": "GROQ_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:GROQ_API_KEY::"
      },
      {
        "name": "COHERE_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:COHERE_API_KEY::"
      },
      {
        "name": "CO_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:CO_API_KEY::"
      },
      {
        "name": "HF_TOKEN",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:HF_TOKEN::"
      },
      {
        "name": "HUGGINGFACE_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:HUGGINGFACE_API_KEY::"
      },
      {
        "name": "DATABRICKS_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:DATABRICKS_API_KEY::"
      },
      {
        "name": "GEMINI_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:GEMINI_API_KEY::"
      },
      {
        "name": "CODESTRAL_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:CODESTRAL_API_KEY::"
      },
      {
        "name": "MISTRAL_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:MISTRAL_API_KEY::"
      },
      {
        "name": "AZURE_AI_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:AZURE_AI_API_KEY::"
      },
      {
        "name": "NVIDIA_NIM_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:NVIDIA_NIM_API_KEY::"
      },
      {
        "name": "XAI_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:XAI_API_KEY::"
      },
      {
        "name": "PERPLEXITYAI_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:PERPLEXITYAI_API_KEY::"
      },
      {
        "name": "GITHUB_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:GITHUB_API_KEY::"
      },
      {
        "name": "DEEPSEEK_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:DEEPSEEK_API_KEY::"
      },
      {
        "name": "AI21_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:AI21_API_KEY::"
      },
      {
        "name": "LANGSMITH_API_KEY",
        "valueFrom": "${aws_secretsmanager_secret_version.litellm_other_secrets_ver.arn}:LANGSMITH_API_KEY::"
      }
    ],
    "portMappings": [
      {
        "containerPort": 4000,
        "protocol": "tcp"
      }
    ]
  },
  {
    "name": "MiddlewareContainer",
    "image": "${var.ecr_middleware_repository_url}:latest",
    "essential": true,
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${var.name}-middleware",
        "awslogs-region": "${data.aws_region.current.name}",
        "awslogs-stream-prefix": "Middleware"
      }
    },
    "environment": [
      { "name": "OKTA_ISSUER", "value": "${var.okta_issuer}" },
      { "name": "OKTA_AUDIENCE", "value": "${var.okta_audience}" }
    ],
    "secrets": [
      {
        "name": "DATABASE_MIDDLEWARE_URL",
        "valueFrom": "${var.middleware_db_secret_arn}"
      },
      {
        "name": "MASTER_KEY",
        "valueFrom": "${var.master_and_salt_key_secret_arn}:LITELLM_MASTER_KEY::"
      }
    ],
    "portMappings": [
      {
        "containerPort": 3000,
        "protocol": "tcp"
      }
    ]
  }
]
DEFINITION
}

###############################################################################
# (9) ECS Service with 2 Target Groups
###############################################################################
resource "aws_ecs_service" "litellm_service" {
  name            = "LiteLLMService"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = var.desired_capacity
  launch_type     = "FARGATE"
  health_check_grace_period_seconds = 300

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.ecs_service_sg.id]
    assign_public_ip = false
  }

  # Attach to both target groups
  load_balancer {
    target_group_arn = aws_lb_target_group.tg_4000.arn
    container_name   = "LiteLLMContainer"
    container_port   = 4000
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg_3000.arn
    container_name   = "MiddlewareContainer"
    container_port   = 3000
  }

  deployment_controller {
    type = "ECS"
  }
  depends_on = [
    aws_lb_listener_rule.bedrock_models,
    aws_lb_listener_rule.openai_completions,
    aws_lb_listener_rule.chat_completions,
    aws_lb_listener_rule.chat_history,
    aws_lb_listener_rule.bedrock_chat_history,
    aws_lb_listener_rule.bedrock_liveliness,
    aws_lb_listener_rule.session_ids,
    aws_lb_listener_rule.key_generate,
    aws_lb_listener_rule.user_new,
    aws_lb_listener_rule.catch_all
  ]
}