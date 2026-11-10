output "service_url" {
  description = "The gateway URL clients call (the alias record, or the ALB's own DNS name)."
  value       = "${var.allow_insecure_http ? "http" : "https"}://${var.record_name != null ? var.record_name : aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  description = "The ALB's own DNS name."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch metrics (observability)."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix for CloudWatch metrics (observability)."
  value       = aws_lb_target_group.litellm.arn_suffix
}

output "ecs_cluster_name" {
  description = "ECS cluster name (observability, smoke test)."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name (observability, smoke test)."
  value       = aws_ecs_service.litellm.name
}

output "log_group_name" {
  description = "The LiteLLM CloudWatch log group (observability)."
  value       = aws_cloudwatch_log_group.litellm.name
}

output "alarm_topic_arn" {
  description = "SNS topic receiving alarm and OK notifications."
  value       = module.observability.sns_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard of the gateway."
  value       = module.observability.dashboard_name
}
