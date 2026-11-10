output "sns_topic_arn" {
  description = "ARN of the SNS topic receiving alarm and OK notifications (module-created or the one passed in)."
  value       = local.sns_topic_arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key created for the alarm topic, or null when not created."
  value       = local.create_kms_key ? aws_kms_key.alarms[0].arn : null
}

output "alarm_names" {
  description = "Names of all CloudWatch alarms created by the module."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.simple : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.math : a.alarm_name],
  )
}

output "alarm_arns" {
  description = "ARNs of all CloudWatch alarms created by the module (e.g. for composite alarms)."
  value       = local.all_alarm_arns
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "redis_cache_cluster_ids" {
  description = "ElastiCache CacheClusterIds monitored (dimension used by ElastiCache node metrics)."
  value       = local.redis_cache_cluster_ids
}
