resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/${var.name}-litellm"
  retention_in_days = 365
}

resource "aws_cloudwatch_log_group" "middleware" {
  name              = "/ecs/${var.name}-middleware"
  retention_in_days = 365
}
