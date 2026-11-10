# ECS Fargate: cluster, the service task definition built ONLY from the
# container.tf locals, the one-off migration task definition, the migration gate
# and CPU+memory target-tracking auto scaling.

resource "aws_ecs_cluster" "this" {
  name = "${var.deployment_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

locals {
  # The ECS shape of local.container (container.tf) — nothing is defined here,
  # only converted. No entryPoint/command override: the image's entrypoint execs
  # `litellm --port 4000`, so the stop signal reaches LiteLLM directly.
  litellm_container = {
    name         = "LiteLLMContainer"
    image        = local.container.image
    essential    = true
    stopTimeout  = local.container.stop_timeout
    environment  = [for k, v in local.container.environment : { name = k, value = v }]
    secrets      = [for k, v in local.container.secrets : { name = k, valueFrom = v }]
    portMappings = [{ containerPort = local.container.port, protocol = "tcp" }]
    healthCheck = {
      command  = local.container.health_check_command
      interval = 30
      timeout  = 10
      # 10 misses (about 5 minutes) before ECS replaces the task: a busy event
      # loop that misses a few probes is not killed with its in-flight streams;
      # the ALB health check already takes it out of rotation within ~90 s.
      # A memory breach (container.tf) must likewise last about 5 minutes
      # before the task is recycled.
      retries     = 10
      startPeriod = 60
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.litellm.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "LiteLLM"
      }
    }
  }

  # The tasks join the foundation's data-ingress group for RDS and Redis access.
  task_security_group_ids = concat(
    [aws_security_group.ecs_service.id],
    var.data_ingress_security_group_id != null ? [var.data_ingress_security_group_id] : [],
  )
}

resource "aws_ecs_task_definition" "litellm" {
  family                   = "${var.deployment_name}-litellm"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.container.vcpus * 1024
  memory                   = local.container.memory_mib
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = local.container.cpu_architecture
  }

  container_definitions = jsonencode([local.litellm_container])
}

# One-off migration task: same image, schema updates on, `--skip_server_startup`
# migrates and exits. Service tasks keep DISABLE_SCHEMA_UPDATE=true.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.deployment_name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = local.container.cpu_architecture
  }

  container_definitions = jsonencode([merge(
    { for k, v in local.litellm_container : k => v if !contains(["healthCheck", "portMappings", "stopTimeout"], k) },
    {
      name        = "Migrate"
      command     = ["--port", tostring(local.container.port), "--skip_server_startup"]
      environment = [for k, v in merge(local.container.environment, { DISABLE_SCHEMA_UPDATE = "false" }) : { name = k, value = v }]
    },
  )])
}

# Config upload, then the schema migration gate (terraform/modules/rollout):
# always run during apply, after the role policies exist (IAM is eventually
# consistent and the migration task reads its secrets at start).
module "rollout" {
  source = "../modules/rollout"

  config_bucket_name               = var.config_bucket_name
  config_object_key                = local.config_object_key
  config_content                   = local.litellm_config_yaml
  region                           = data.aws_region.current.region
  cluster_name                     = aws_ecs_cluster.this.name
  migrate_task_definition_arn      = aws_ecs_task_definition.migrate.arn
  migrate_task_definition_revision = aws_ecs_task_definition.migrate.revision
  image                            = local.container.image
  subnet_ids                       = var.private_subnet_ids
  security_group_ids               = local.task_security_group_ids

  depends_on = [aws_iam_role_policy.execution, aws_iam_role_policy.task]
}

resource "aws_ecs_service" "litellm" {
  name                              = "${var.deployment_name}-litellm"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.litellm.arn
  desired_count                     = local.scaling.desired
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120

  # Room for a replacement task next to every running one: deploys roll
  # without capacity loss, and a task that fails its container health check
  # (container.tf: liveliness or memory recycle) is replaced before it stops.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = local.task_security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "LiteLLMContainer"
    container_port   = local.container.port
  }

  deployment_controller {
    type = "ECS"
  }

  # Auto scaling owns the task count after creation: redeploys never reset it.
  lifecycle {
    ignore_changes = [desired_count]
  }

  # The target group must be attached to a listener, the role policies must
  # exist, and the config must be uploaded and the schema migrated (module
  # rollout), before tasks roll.
  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_iam_role_policy.execution,
    aws_iam_role_policy.task,
    module.rollout,
  ]
}

locals {
  scaling = {
    # Two tasks in two AZs at creation and as the floor; after creation auto
    # scaling owns the count and redeploys never reset it.
    desired = 2
    min     = 2
    # Up to 20 tasks. The foundation's free-IP check (max_gateway_instances)
    # and the RDS connection alarm (20 x ~10 connections x 2 during a deploy)
    # are sized for the same 20.
    max = 20
    # LiteLLM runs a single worker process, which saturates at one vCPU: on a
    # 2-vCPU task the service CPU average levels off at about 50 %, and latency
    # starts to climb from about 40 %. The target scales out below that point.
    cpu_target_percent    = 35
    memory_target_percent = 70
  }
}

resource "aws_appautoscaling_target" "litellm" {
  max_capacity       = local.scaling.max
  min_capacity       = local.scaling.min
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.litellm.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.deployment_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.litellm.resource_id
  scalable_dimension = aws_appautoscaling_target.litellm.scalable_dimension
  service_namespace  = aws_appautoscaling_target.litellm.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = local.scaling.cpu_target_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 120
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.deployment_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.litellm.resource_id
  scalable_dimension = aws_appautoscaling_target.litellm.scalable_dimension
  service_namespace  = aws_appautoscaling_target.litellm.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = local.scaling.memory_target_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
