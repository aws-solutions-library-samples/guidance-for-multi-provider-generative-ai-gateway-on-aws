# Load-test infrastructure inside the gateway VPC, separate from the gateway's
# own state: a fake OpenAI-compatible upstream (ECS Fargate behind an internal
# NLB) and a locust driver (EC2, operated through SSM Run Command, no inbound
# access). Everything is named with var.name_prefix and is meant to be
# destroyed after the test.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = var.name_prefix
  tags = merge(var.tags, { Purpose = "load-test" })
}

# ---------------------------------------------------------------------------
# Artifacts bucket: the locust scenario and driver script go in, results come
# out. Private, encrypted, TLS-only; emptied on destroy.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "artifacts_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket     = aws_s3_bucket.artifacts.id
  policy     = data.aws_iam_policy_document.artifacts_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

resource "aws_s3_object" "scenario" {
  for_each = {
    "scenario/locustfile.py" = "${path.module}/../locust/locustfile.py"
    "scenario/run-driver.sh" = "${path.module}/../scripts/run-driver.sh"
  }
  bucket = aws_s3_bucket.artifacts.id
  key    = each.key
  source = each.value
  etag   = filemd5(each.value)
}

# The gateway virtual key the driver uses. Created empty; `scripts/gateway.sh setup`
# stores the key it generates. Deleted immediately on destroy.
resource "aws_secretsmanager_secret" "api_key" {
  name                    = "${local.name}-api-key"
  description             = "LiteLLM virtual key for the load-test driver"
  recovery_window_in_days = 0
  tags                    = local.tags
}

# ---------------------------------------------------------------------------
# Fake upstream: ECS Fargate service behind an internal NLB.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "fake" {
  name              = "/ecs/${local.name}-fake-upstream"
  retention_in_days = 7
  tags              = local.tags
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fake_execution" {
  name               = "${local.name}-fake-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "fake_execution" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fake.arn}:*"]
  }
}

resource "aws_iam_role_policy" "fake_execution" {
  name   = "logs"
  role   = aws_iam_role.fake_execution.id
  policy = data.aws_iam_policy_document.fake_execution.json
}

locals {
  fake_port = 8080
  # The server source travels in the task definition (no image build): the
  # stock Python image installs the one dependency and runs it.
  fake_command = join(" && ", [
    "pip install --no-cache-dir --disable-pip-version-check --root-user-action=ignore -q aiohttp==${var.aiohttp_version}",
    "echo \"$FAKE_SERVER_B64\" | base64 -d > /tmp/server.py",
    "exec python /tmp/server.py",
  ])
}

resource "aws_ecs_task_definition" "fake" {
  family                   = "${local.name}-fake-upstream"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fake_task_cpu
  memory                   = var.fake_task_cpu * 2
  execution_role_arn       = aws_iam_role.fake_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name        = "fake-upstream"
    image       = var.python_image
    essential   = true
    entryPoint  = ["sh", "-c"]
    command     = [local.fake_command]
    stopTimeout = 10
    environment = [for k, v in {
      FAKE_SERVER_B64       = filebase64("${path.module}/../fake_upstream/server.py")
      FAKE_HOST             = "0.0.0.0" # private subnets; the security groups are the boundary
      FAKE_PORT             = tostring(local.fake_port)
      FAKE_WORKERS          = tostring(var.fake_task_cpu / 1024 * 2)
      FAKE_TTFT_MS          = tostring(var.fake_profile.ttft_ms)
      FAKE_ITL_MS           = tostring(var.fake_profile.itl_ms)
      FAKE_TOKENS_MIN       = tostring(var.fake_profile.tokens_min)
      FAKE_TOKENS_MAX       = tostring(var.fake_profile.tokens_max)
      FAKE_JITTER           = tostring(var.fake_profile.jitter)
      FAKE_TOKENS_PER_CHUNK = tostring(var.fake_profile.tokens_per_chunk)
    } : { name = k, value = v }]
    portMappings = [{ containerPort = local.fake_port, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.fake.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "fake"
      }
    }
  }])
  tags = local.tags
}

resource "aws_security_group" "nlb" {
  name        = "${local.name}-nlb-sg"
  description = "Load test: fake upstream NLB"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_clients" {
  for_each = {
    gateway = var.gateway_security_group_id
    driver  = aws_security_group.driver.id
  }
  security_group_id            = aws_security_group.nlb.id
  description                  = "Fake upstream clients (${each.key})"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_fake" {
  security_group_id            = aws_security_group.nlb.id
  description                  = "NLB to fake upstream tasks"
  referenced_security_group_id = aws_security_group.fake.id
  ip_protocol                  = "tcp"
  from_port                    = local.fake_port
  to_port                      = local.fake_port
}

resource "aws_security_group" "fake" {
  name        = "${local.name}-fake-sg"
  description = "Load test: fake upstream tasks"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "fake_from_nlb" {
  security_group_id            = aws_security_group.fake.id
  description                  = "NLB to fake upstream"
  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = local.fake_port
  to_port                      = local.fake_port
}

resource "aws_vpc_security_group_egress_rule" "fake_https" {
  security_group_id = aws_security_group.fake.id
  description       = "Image pull and package install (HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_lb" "fake" {
  name                             = "${local.name}-fake"
  load_balancer_type               = "network"
  internal                         = true
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.nlb.id]
  enable_cross_zone_load_balancing = true
  tags                             = local.tags
}

resource "aws_lb_target_group" "fake" {
  name                 = "${local.name}-fake"
  port                 = local.fake_port
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 10

  health_check {
    protocol            = "HTTP"
    path                = "/health"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = local.tags
}

resource "aws_lb_listener" "fake" {
  load_balancer_arn = aws_lb.fake.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fake.arn
  }
  tags = local.tags
}

resource "aws_ecs_service" "fake" {
  name            = "${local.name}-fake-upstream"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.fake.arn
  desired_count   = var.fake_task_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.fake.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.fake.arn
    container_name   = "fake-upstream"
    container_port   = local.fake_port
  }

  depends_on = [aws_lb_listener.fake]
  tags       = local.tags
}

# ---------------------------------------------------------------------------
# Locust driver: one EC2 instance, no inbound rules, reached through SSM.
# ---------------------------------------------------------------------------

resource "aws_security_group" "driver" {
  name        = "${local.name}-driver-sg"
  description = "Load test: locust driver (no inbound)"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_egress_rule" "driver_all" {
  security_group_id = aws_security_group.driver.id
  description       = "Gateway ALB, fake upstream, SSM, S3, package install"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "driver" {
  name               = "${local.name}-driver"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "driver_ssm" {
  role       = aws_iam_role.driver.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "driver" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactsList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
  statement {
    sid       = "ApiKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.api_key.arn]
  }
}

resource "aws_iam_role_policy" "driver" {
  name   = "load-test"
  role   = aws_iam_role.driver.id
  policy = data.aws_iam_policy_document.driver.json
}

resource "aws_iam_instance_profile" "driver" {
  name = "${local.name}-driver"
  role = aws_iam_role.driver.name
  tags = local.tags
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "driver" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type          = var.driver_instance_type
  subnet_id              = var.subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.driver.id]
  iam_instance_profile   = aws_iam_instance_profile.driver.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/driver-user-data.sh.tftpl", {
    locust_version = var.locust_version
  })
  user_data_replace_on_change = true

  tags = merge(local.tags, { Name = "${local.name}-driver" })

  lifecycle {
    ignore_changes = [ami]
  }
}
