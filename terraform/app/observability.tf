# Alarms, dashboard and the encrypted alarm topic. Data-store
# dimensions come from foundation outputs; Container Insights, which the
# running-task alarm needs, is enabled on the cluster (ecs.tf).

module "observability" {
  source = "../modules/observability"

  deployment_name            = var.deployment_name
  alb_arn_suffix             = aws_lb.this.arn_suffix
  target_group_arn_suffix    = aws_lb_target_group.litellm.arn_suffix
  ecs_cluster_name           = aws_ecs_cluster.this.name
  ecs_service_name           = aws_ecs_service.litellm.name
  rds_instance_identifier    = var.rds_instance_identifier
  redis_replication_group_id = var.redis_replication_group_id
  redis_num_cache_clusters   = var.redis_num_cache_clusters
  log_group_name             = aws_cloudwatch_log_group.litellm.name
  kms_key_arn                = var.kms_key_arn
  alarm_email                = var.alarm_email

  # LLM responses are measured to the last byte and routinely take tens of
  # seconds: 60 s catches stuck or saturated targets; the 5XX alarms are the
  # primary failure signal.
  latency_p90_threshold_seconds = 60
}
