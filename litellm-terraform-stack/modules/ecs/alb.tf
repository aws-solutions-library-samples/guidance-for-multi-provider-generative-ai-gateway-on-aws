###############################################################################
# (8) Application Load Balancer, Listener, Target Groups
###############################################################################
# ALB
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  subnets            = var.public_load_balancer ? var.public_subnets : var.private_subnets
  # You need to supply a security group for the ALB itself:
  security_groups    = [aws_security_group.alb_sg.id]
  internal           = var.public_load_balancer ? false : true
  idle_timeout       = 60
  drop_invalid_header_fields = true
  access_logs {
    bucket  = aws_s3_bucket.access_log_bucket.bucket
    prefix  = "alb-access-logs-"
    enabled = true
   }
}

# HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  # Instead of a fixed-response 404, use tg_4000 as the default.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_4000.arn
  }
}

# Target Group for port 4000 (LiteLLMContainer)
resource "aws_lb_target_group" "tg_4000" {
  name        = "${var.name}-4000"
  port        = 4000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health/liveliness"
    port                = "4000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }
}

# Target Group for port 3000 (MiddlewareContainer)
resource "aws_lb_target_group" "tg_3000" {
  name        = "${var.name}-3000"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/bedrock/health/liveliness"
    port                = "3000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }
}

resource "aws_lb_listener_rule" "catch_all" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 99

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_4000.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}


# Example: Listener Rules for path patterns & priorities
# bedrock model
resource "aws_lb_listener_rule" "bedrock_models" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 16

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/bedrock/model/*"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# OpenAICompletions
resource "aws_lb_listener_rule" "openai_completions" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 15

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/v1/chat/completions"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# ChatCompletions
resource "aws_lb_listener_rule" "chat_completions" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 14

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/chat/completions"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# ChatHistory
resource "aws_lb_listener_rule" "chat_history" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 8

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/chat-history"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# BedrockChatHistory
resource "aws_lb_listener_rule" "bedrock_chat_history" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 9

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/bedrock/chat-history"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# BedrockLiveliness
resource "aws_lb_listener_rule" "bedrock_liveliness" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/bedrock/health/liveliness"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# SessionIds
resource "aws_lb_listener_rule" "session_ids" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 11

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/session-ids"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# KeyGenerate
resource "aws_lb_listener_rule" "key_generate" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 12

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/key/generate"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

# UserNew
resource "aws_lb_listener_rule" "user_new" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 13

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }

  condition {
    path_pattern {
      values = ["/user/new"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET", "PUT"]
    }
  }
}

###############################################################################
# (11) Application Auto Scaling (CPU & Memory)
###############################################################################
resource "aws_appautoscaling_target" "ecs_service_target" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.litellm_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu_policy" {
  name               = "${var.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_utilization_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "memory_policy" {
  name               = "${var.name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.memory_target_utilization_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}
