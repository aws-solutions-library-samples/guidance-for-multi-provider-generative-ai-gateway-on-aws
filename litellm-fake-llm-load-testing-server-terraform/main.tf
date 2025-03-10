# Data sources
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

data "aws_route53_zone" "hosted_zone" {
  name = var.fake_llm_load_testing_endpoint_hosted_zone_name
}

data "aws_ecr_repository" "fake_server_repo" {
  name = var.ecr_fake_server_repository
}

# ECS Cluster
resource "aws_ecs_cluster" "fake_llm_cluster" {
  name = "FakeLlmCluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "fake_server_task_def" {
  family                   = "FakeServerTaskDef"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  
  runtime_platform {
    cpu_architecture        = var.architecture == "x86" ? "X86_64" : "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "FakeServerContainer"
      image     = "${data.aws_ecr_repository.fake_server_repo.repository_url}:latest"
      essential = true
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.fake_server_logs.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "FakeServer"
        }
      }
      
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
    }
  ])
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "fake_server_logs" {
  name              = "/ecs/FakeServer"
  retention_in_days = 30
}

# IAM Roles
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "FakeServerEcsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "FakeServerEcsTaskRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Application Load Balancer
resource "aws_lb" "fake_server_alb" {
  name               = "FakeServer-ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.public.ids

  enable_deletion_protection = false
}

# ALB HTTPS Listener
resource "aws_lb_listener" "fake_server_listener" {
  load_balancer_arn = aws_lb.fake_server_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.fake_llm_load_testing_endpoint_certifiacte_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fake_server_tg.arn
  }
}

# Target Group
resource "aws_lb_target_group" "fake_server_tg" {
  name        = "FakeServer-TG"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    protocol            = "HTTP"
    matcher             = "200-399"
  }
}

# Security Groups
resource "aws_security_group" "alb_sg" {
  name        = "fake-server-alb-sg"
  description = "Allow HTTPS inbound traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = "fake-server-ecs-sg"
  description = "Allow inbound traffic from ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Service
resource "aws_ecs_service" "fake_server_service" {
  name                               = "FakeServer"
  cluster                            = aws_ecs_cluster.fake_llm_cluster.id
  task_definition                    = aws_ecs_task_definition.fake_server_task_def.arn
  desired_count                      = 3
  launch_type                        = "FARGATE"
  health_check_grace_period_seconds  = 300
  
  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.fake_server_tg.arn
    container_name   = "FakeServerContainer"
    container_port   = 8080
  }
}

# Route 53 Record
resource "aws_route53_record" "fake_server_dns" {
  zone_id = data.aws_route53_zone.hosted_zone.zone_id
  name    = var.fake_llm_load_testing_endpoint_record_name
  type    = "A"

  alias {
    name                   = aws_lb.fake_server_alb.dns_name
    zone_id                = aws_lb.fake_server_alb.zone_id
    evaluate_target_health = true
  }
}

