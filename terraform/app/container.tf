# Container settings live in this file: the ECS task definition and the
# migration task are built from local.container, and any non-ECS runtime can
# mirror it. Do not scatter image, port, env, secrets or health-check settings
# elsewhere.

# Task size and the container health check, outside local.container because
# the health check derives its memory threshold from the task size.
locals {
  task_vcpus      = 2
  task_memory_mib = local.task_vcpus * 2048 # 2 GiB per vCPU

  # The health check (templates/healthcheck.py.tftpl) runs inline with the
  # image's python3; nothing is added to the image. It is unhealthy when
  # LiteLLM does not answer on its liveliness path (the ALB target group checks
  # the same path), or when the whole task's memory, without reclaimable page
  # cache, reaches memory_recycle_percent of the task memory. ECS then starts a
  # replacement before it stops the task (ecs.tf: deployment maximum 200 %),
  # and the old task drains, so memory that LiteLLM does not return over time
  # is recycled instead of growing until the task runs out of memory. Above the
  # 70 % memory scale-out target (ecs.tf), so a fresh task is not recycled.
  # The memory part fails open when the task metadata endpoint is unavailable.
  memory_recycle_percent = 90
  health_check_script = replace(templatefile("${path.module}/templates/healthcheck.py.tftpl", {
    liveliness_url = "http://localhost:4000/health/liveliness"
    threshold_mib  = floor(local.task_memory_mib * local.memory_recycle_percent / 100)
  }), "/(?m)^[ ]*#.*\n/", "") # comment lines dropped: the command stays short
}

locals {
  container = {
    # Official upstream image at the pinned upstream release, pinned by the
    # digest of its multi-architecture index so every task pulls exactly the
    # reviewed image even if the tag is re-pushed; the tag is kept for
    # readability. To upgrade, bump BOTH the tag and the digest, and re-check
    # signal handling, the schema migration, the log format and the OIDC route
    # list (alb.tf) when moving to another minor line.
    # image_uri overrides it for air-gapped deployments that mirrored the image
    # into a private registry (for example the account's ECR).
    # Graviton tasks with 2 vCPU and 4 GiB (memory is 2 GiB per vCPU); the
    # official image is multi-architecture.
    cpu_architecture = "ARM64"
    vcpus            = local.task_vcpus
    memory_mib       = local.task_memory_mib

    image = coalesce(var.image_uri, "ghcr.io/berriai/litellm:v1.106.6@sha256:37e2dafb088a7723beb998590682957386dfc83ffea1848486f8e0e5cfac0b06")
    port  = 4000

    # Plain environment values (secrets never go here). Service tasks must run
    # DISABLE_SCHEMA_UPDATE=true: only the one-off migration task (which flips it
    # and passes --skip_server_startup) migrates the schema.
    environment = merge(
      {
        LITELLM_LOG                      = var.log_level # LiteLLM writes prompts at DEBUG; INFO is the default
        JSON_LOGS                        = "True"
        LITELLM_CONFIG_BUCKET_NAME       = var.config_bucket_name
        LITELLM_CONFIG_BUCKET_OBJECT_KEY = local.config_object_key
        LITELLM_CONFIG_SHA               = local.config_sha # a config change makes a new revision, so a rolling deploy
        UI_USERNAME                      = "admin"
        REDIS_HOST                       = var.redis_endpoint
        REDIS_PORT                       = tostring(var.redis_port)
        REDIS_SSL                        = "True"
        DISABLE_SCHEMA_UPDATE            = "true"
        LITELLM_LOCAL_MODEL_COST_MAP     = "True" # no start-up fetch from raw.githubusercontent.com
        # uvicorn keep-alive outlasts the ALB idle timeout, so the ALB never
        # reuses a connection the task has just closed (sporadic 502s).
        KEEPALIVE_TIMEOUT = tostring(local.alb_idle_timeout_seconds + 5)
      },
      var.extra_environment,
    )

    # name -> Secrets Manager ARN; values are injected by the runtime, never by Terraform.
    secrets = merge(
      {
        DATABASE_URL       = var.database_url_secret_arn
        LITELLM_MASTER_KEY = var.master_key_secret_arn
        LITELLM_SALT_KEY   = var.salt_key_secret_arn
        REDIS_PASSWORD     = var.redis_auth_secret_arn
        UI_PASSWORD        = var.ui_password_secret_arn # separate from the master key
      },
      # Reduced mode without a licence; Enterprise features need LITELLM_LICENSE (no rebuild to switch).
      var.litellm_license_secret_arn != null ? { LITELLM_LICENSE = var.litellm_license_secret_arn } : {},
      var.provider_secret_arns,
    )

    # Liveliness and memory-recycle health check (see local.health_check_script above).
    health_check_path    = "/health/liveliness"
    health_check_command = ["CMD-SHELL", "python3 -c \"${local.health_check_script}\" || exit 1"]

    # Drain window: 120 s (Fargate's maximum), aligned with the target
    # deregistration delay, so in-flight requests get this long to finish on a
    # deploy or scale-in. Unrelated to the ALB idle timeout (alb.tf), which
    # bounds silence on a live connection.
    stop_timeout = 120
  }
}
