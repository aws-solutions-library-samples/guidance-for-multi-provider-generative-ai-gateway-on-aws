resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/${var.name}-litellm"
  retention_in_days = 30  # Adjust retention period as needed
}

resource "aws_cloudwatch_log_group" "middleware" {
  name              = "/ecs/${var.name}-middleware"
  retention_in_days = 30  # Adjust retention period as needed
}
