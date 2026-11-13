# All signals come from AWS service metrics (plus one optional log metric filter); no custom code.
#
# treat_missing_data choices:
#   notBreaching - signals that are absent when there is simply no traffic or nothing wrong
#                  (5XX counts/rates, latency, unhealthy hosts, evictions, replication lag, log errors).
#   breaching    - signals that are always published while the service exists, so a gap means
#                  the resource or its metrics are gone (healthy hosts, ECS running vs desired).
#   missing      - periodic resource metrics where a gap is not by itself a problem (CPU, memory,
#                  storage, connections); the alarm keeps its last state.

locals {
  redis_metric_ids = { for i, id in local.redis_cache_cluster_ids : "m${i}" => id }
  redis_max_expr   = "MAX([${join(",", keys(local.redis_metric_ids))}])"

  # Single-metric alarms.
  simple_alarms = merge(
    {
      alb-elb-5xx = {
        description         = "ALB returned more than ${var.elb_5xx_threshold} 5XX responses itself (no healthy targets, target timeouts or connection errors)."
        namespace           = "AWS/ApplicationELB"
        metric_name         = "HTTPCode_ELB_5XX_Count"
        dimensions          = local.alb_dims
        statistic           = "Sum"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.elb_5xx_threshold
        evaluation_periods  = 3
        datapoints_to_alarm = 2
        treat_missing_data  = "notBreaching"
      }
      alb-latency-p90 = {
        description         = "p90 TargetResponseTime above ${var.latency_p90_threshold_seconds}s. Streaming responses are measured until the last byte, so long generations inflate this."
        namespace           = "AWS/ApplicationELB"
        metric_name         = "TargetResponseTime"
        dimensions          = local.tg_dims
        statistic           = null
        extended_statistic  = "p90"
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.latency_p90_threshold_seconds
        evaluation_periods  = 3
        datapoints_to_alarm = 2
        treat_missing_data  = "notBreaching"
      }
      alb-unhealthy-hosts = {
        description         = "At least one LiteLLM target is failing ALB health checks."
        namespace           = "AWS/ApplicationELB"
        metric_name         = "UnHealthyHostCount"
        dimensions          = local.tg_dims
        statistic           = "Maximum"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        evaluation_periods  = 3
        datapoints_to_alarm = 2
        treat_missing_data  = "notBreaching"
      }
      alb-no-healthy-hosts = {
        description         = "No healthy LiteLLM targets behind the ALB: the gateway is down."
        namespace           = "AWS/ApplicationELB"
        metric_name         = "HealthyHostCount"
        dimensions          = local.tg_dims
        statistic           = "Minimum"
        extended_statistic  = null
        comparison_operator = "LessThanThreshold"
        threshold           = 1
        evaluation_periods  = 2
        datapoints_to_alarm = 2
        treat_missing_data  = "breaching"
      }
      ecs-cpu-high = {
        description         = "LiteLLM ECS service average CPU above ${var.ecs_cpu_threshold_percent}%."
        namespace           = "AWS/ECS"
        metric_name         = "CPUUtilization"
        dimensions          = local.ecs_dims
        statistic           = "Average"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.ecs_cpu_threshold_percent
        evaluation_periods  = 5
        datapoints_to_alarm = 4
        treat_missing_data  = "missing"
      }
      ecs-memory-high = {
        description         = "LiteLLM ECS service average memory above ${var.ecs_memory_threshold_percent}%."
        namespace           = "AWS/ECS"
        metric_name         = "MemoryUtilization"
        dimensions          = local.ecs_dims
        statistic           = "Average"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.ecs_memory_threshold_percent
        evaluation_periods  = 5
        datapoints_to_alarm = 4
        treat_missing_data  = "missing"
      }
      rds-cpu-high = {
        description         = "RDS CPUUtilization above ${var.rds_cpu_threshold_percent}%."
        namespace           = "AWS/RDS"
        metric_name         = "CPUUtilization"
        dimensions          = local.rds_dims
        statistic           = "Average"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.rds_cpu_threshold_percent
        evaluation_periods  = 5
        datapoints_to_alarm = 4
        treat_missing_data  = "missing"
      }
      rds-free-storage-low = {
        description         = "RDS FreeStorageSpace below ${var.rds_free_storage_threshold_gib} GiB."
        namespace           = "AWS/RDS"
        metric_name         = "FreeStorageSpace"
        dimensions          = local.rds_dims
        statistic           = "Minimum"
        extended_statistic  = null
        comparison_operator = "LessThanThreshold"
        threshold           = var.rds_free_storage_threshold_gib * 1024 * 1024 * 1024
        evaluation_periods  = 1
        datapoints_to_alarm = 1
        treat_missing_data  = "missing"
      }
      rds-connections-high = {
        description         = "RDS DatabaseConnections above ${var.rds_connections_threshold}."
        namespace           = "AWS/RDS"
        metric_name         = "DatabaseConnections"
        dimensions          = local.rds_dims
        statistic           = "Maximum"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.rds_connections_threshold
        evaluation_periods  = 3
        datapoints_to_alarm = 3
        treat_missing_data  = "missing"
      }
    },
    var.enable_log_metrics ? {
      log-errors = {
        description         = "LiteLLM logged more than ${var.log_error_threshold} ERROR lines (provider failures, auth failures, DB/cache errors)."
        namespace           = local.log_metric_namespace
        metric_name         = local.log_error_metric
        dimensions          = {}
        statistic           = "Sum"
        extended_statistic  = null
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.log_error_threshold
        evaluation_periods  = 3
        datapoints_to_alarm = 2
        treat_missing_data  = "notBreaching"
      }
    } : {}
  )

  # Metric math alarms.
  math_alarms = merge(
    {
      alb-target-5xx-rate = {
        description         = "LiteLLM target 5XX error rate above ${var.error_rate_threshold_percent}% (evaluated only with at least ${var.error_rate_min_requests} requests per period)."
        expression          = "IF(requests >= ${var.error_rate_min_requests}, 100 * FILL(errors, 0) / requests, 0)"
        label               = "Target 5XX error rate (%)"
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.error_rate_threshold_percent
        evaluation_periods  = 3
        datapoints_to_alarm = 2
        treat_missing_data  = "notBreaching"
        metrics = {
          errors   = { namespace = "AWS/ApplicationELB", metric_name = "HTTPCode_Target_5XX_Count", dimensions = local.tg_dims, stat = "Sum" }
          requests = { namespace = "AWS/ApplicationELB", metric_name = "RequestCount", dimensions = local.tg_dims, stat = "Sum" }
        }
      }
      # Container Insights metrics; tolerate short dips during deployments and scale-out.
      ecs-running-below-desired = {
        description         = "LiteLLM ECS service is running fewer tasks than desired."
        expression          = "desired - running"
        label               = "Missing tasks"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        evaluation_periods  = 5
        datapoints_to_alarm = 5
        treat_missing_data  = "breaching"
        metrics = {
          running = { namespace = "ECS/ContainerInsights", metric_name = "RunningTaskCount", dimensions = local.ecs_dims, stat = "Average" }
          desired = { namespace = "ECS/ContainerInsights", metric_name = "DesiredTaskCount", dimensions = local.ecs_dims, stat = "Average" }
        }
      }
      redis-engine-cpu-high = {
        description         = "Redis EngineCPUUtilization above ${var.redis_engine_cpu_threshold_percent}% on at least one node."
        expression          = local.redis_max_expr
        label               = "Max EngineCPUUtilization (%)"
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.redis_engine_cpu_threshold_percent
        evaluation_periods  = 5
        datapoints_to_alarm = 4
        treat_missing_data  = "missing"
        metrics             = { for k, id in local.redis_metric_ids : k => { namespace = "AWS/ElastiCache", metric_name = "EngineCPUUtilization", dimensions = { CacheClusterId = id }, stat = "Average" } }
      }
      redis-memory-high = {
        description         = "Redis DatabaseMemoryUsagePercentage above ${var.redis_memory_threshold_percent}% on at least one node."
        expression          = local.redis_max_expr
        label               = "Max DatabaseMemoryUsagePercentage (%)"
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.redis_memory_threshold_percent
        evaluation_periods  = 5
        datapoints_to_alarm = 4
        treat_missing_data  = "missing"
        metrics             = { for k, id in local.redis_metric_ids : k => { namespace = "AWS/ElastiCache", metric_name = "DatabaseMemoryUsagePercentage", dimensions = { CacheClusterId = id }, stat = "Maximum" } }
      }
      redis-evictions = {
        description         = "Redis is evicting keys (memory pressure): cached responses and rate-limit state are being dropped."
        expression          = local.redis_max_expr
        label               = "Max Evictions"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        evaluation_periods  = 3
        datapoints_to_alarm = 2
        treat_missing_data  = "notBreaching"
        metrics             = { for k, id in local.redis_metric_ids : k => { namespace = "AWS/ElastiCache", metric_name = "Evictions", dimensions = { CacheClusterId = id }, stat = "Sum" } }
      }
      redis-connections-high = {
        description         = "Redis CurrConnections above ${var.redis_connections_threshold} on at least one node."
        expression          = local.redis_max_expr
        label               = "Max CurrConnections"
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.redis_connections_threshold
        evaluation_periods  = 3
        datapoints_to_alarm = 3
        treat_missing_data  = "missing"
        metrics             = { for k, id in local.redis_metric_ids : k => { namespace = "AWS/ElastiCache", metric_name = "CurrConnections", dimensions = { CacheClusterId = id }, stat = "Maximum" } }
      }
    },
    # ReplicationLag is only published by replicas; MAX across all members survives failover.
    length(local.redis_cache_cluster_ids) > 1 ? {
      redis-replication-lag = {
        description         = "Redis replica ReplicationLag above ${var.redis_replication_lag_threshold_seconds}s."
        expression          = local.redis_max_expr
        label               = "Max ReplicationLag (s)"
        comparison_operator = "GreaterThanThreshold"
        threshold           = var.redis_replication_lag_threshold_seconds
        evaluation_periods  = 3
        datapoints_to_alarm = 3
        treat_missing_data  = "notBreaching"
        metrics             = { for k, id in local.redis_metric_ids : k => { namespace = "AWS/ElastiCache", metric_name = "ReplicationLag", dimensions = { CacheClusterId = id }, stat = "Maximum" } }
      }
    } : {}
  )

  alarm_actions = var.alarm_actions_enabled ? [local.sns_topic_arn] : []
}

resource "aws_cloudwatch_metric_alarm" "simple" {
  for_each = local.simple_alarms

  alarm_name          = "${var.deployment_name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  period              = var.alarm_period_seconds
  comparison_operator = each.value.comparison_operator
  threshold           = each.value.threshold
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  treat_missing_data  = each.value.treat_missing_data
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "math" {
  for_each = local.math_alarms

  alarm_name          = "${var.deployment_name}-${each.key}"
  alarm_description   = each.value.description
  comparison_operator = each.value.comparison_operator
  threshold           = each.value.threshold
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  treat_missing_data  = each.value.treat_missing_data
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags

  metric_query {
    id          = "e1"
    expression  = each.value.expression
    label       = each.value.label
    return_data = true
  }

  dynamic "metric_query" {
    for_each = each.value.metrics

    content {
      id = metric_query.key

      metric {
        namespace   = metric_query.value.namespace
        metric_name = metric_query.value.metric_name
        dimensions  = metric_query.value.dimensions
        stat        = metric_query.value.stat
        period      = var.alarm_period_seconds
      }
    }
  }
}
