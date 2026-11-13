locals {
  p = var.alarm_period_seconds

  alb  = ["LoadBalancer", var.alb_arn_suffix]
  tg   = ["LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix]
  ecs  = ["ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
  rds  = ["DBInstanceIdentifier", var.rds_instance_identifier]
  elbn = "AWS/ApplicationELB"

  redis_series = { for metric in ["EngineCPUUtilization", "DatabaseMemoryUsagePercentage", "CurrConnections", "Evictions"] :
    metric => [for id in local.redis_cache_cluster_ids : ["AWS/ElastiCache", metric, "CacheClusterId", id, { label = id }]]
  }

  all_alarm_arns = concat(
    [for a in aws_cloudwatch_metric_alarm.simple : a.arn],
    [for a in aws_cloudwatch_metric_alarm.math : a.arn],
  )

  text = { for k, v in {
    header = "# ${var.deployment_name} LiteLLM gateway\nAWS service metrics only (ALB, ECS/Container Insights, RDS, ElastiCache). ALB latency includes streaming time until the last byte."
    infra  = "## ECS, RDS and Redis"
  } : k => { type = "text", properties = { markdown = v } } }

  graph = { region = local.region, view = "timeSeries", stacked = false, period = local.p }

  widgets = [
    merge(local.text.header, { x = 0, y = 0, width = 24, height = 2 }),

    # Requests and availability
    { type = "metric", x = 0, y = 2, width = 8, height = 6, properties = merge(local.graph, {
      title   = "Requests"
      stat    = "Sum"
      metrics = [concat([local.elbn, "RequestCount"], local.tg, [{ label = "Requests" }])]
    }) },
    { type = "metric", x = 8, y = 2, width = 8, height = 6, properties = merge(local.graph, {
      title = "Availability (%)"
      yAxis = { left = { min = 0, max = 100 } }
      metrics = [
        [{ expression = "IF(req > 0, 100 * (1 - (FILL(t5, 0) + FILL(e5, 0)) / req), 100)", label = "Availability (%)", id = "avail" }],
        concat([local.elbn, "RequestCount"], local.alb, [{ id = "req", stat = "Sum", visible = false }]),
        concat([local.elbn, "HTTPCode_Target_5XX_Count"], local.alb, [{ id = "t5", stat = "Sum", visible = false }]),
        concat([local.elbn, "HTTPCode_ELB_5XX_Count"], local.alb, [{ id = "e5", stat = "Sum", visible = false }]),
      ]
    }) },
    { type = "metric", x = 16, y = 2, width = 8, height = 6, properties = merge(local.graph, {
      title = "Errors"
      stat  = "Sum"
      metrics = concat(
        [
          concat([local.elbn, "HTTPCode_Target_5XX_Count"], local.tg, [{ label = "Target 5XX" }]),
          concat([local.elbn, "HTTPCode_Target_4XX_Count"], local.tg, [{ label = "Target 4XX" }]),
          concat([local.elbn, "HTTPCode_ELB_5XX_Count"], local.alb, [{ label = "ALB 5XX" }]),
        ],
        var.enable_log_metrics ? [[local.log_metric_namespace, local.log_error_metric, { label = "LiteLLM ERROR log lines" }]] : []
      )
    }) },

    # Error rate and latency
    { type = "metric", x = 0, y = 8, width = 12, height = 6, properties = merge(local.graph, {
      title = "Target 5XX error rate (%)"
      yAxis = { left = { min = 0 } }
      metrics = [
        [{ expression = "IF(req > 0, 100 * FILL(err, 0) / req, 0)", label = "Error rate (%)", id = "rate" }],
        concat([local.elbn, "HTTPCode_Target_5XX_Count"], local.tg, [{ id = "err", stat = "Sum", visible = false }]),
        concat([local.elbn, "RequestCount"], local.tg, [{ id = "req", stat = "Sum", visible = false }]),
      ]
      annotations = { horizontal = [{ label = "Alarm", value = var.error_rate_threshold_percent }] }
    }) },
    { type = "metric", x = 12, y = 8, width = 12, height = 6, properties = merge(local.graph, {
      title = "Target response time (s)"
      yAxis = { left = { min = 0 } }
      metrics = [for s in ["p50", "p90", "p99"] :
        concat([local.elbn, "TargetResponseTime"], local.tg, [{ stat = s, label = s }])
      ]
      annotations = { horizontal = [{ label = "p90 alarm", value = var.latency_p90_threshold_seconds }] }
    }) },

    merge(local.text.infra, { x = 0, y = 14, width = 24, height = 1 }),

    # ECS
    { type = "metric", x = 0, y = 15, width = 8, height = 6, properties = merge(local.graph, {
      title   = "ECS CPU / memory (%)"
      stat    = "Average"
      yAxis   = { left = { min = 0, max = 100 } }
      metrics = [for m in ["CPUUtilization", "MemoryUtilization"] : concat(["AWS/ECS", m], local.ecs)]
    }) },
    { type = "metric", x = 8, y = 15, width = 8, height = 6, properties = merge(local.graph, {
      title   = "ECS tasks"
      stat    = "Average"
      metrics = [for m in ["RunningTaskCount", "DesiredTaskCount", "PendingTaskCount"] : concat(["ECS/ContainerInsights", m], local.ecs)]
    }) },
    { type = "metric", x = 16, y = 15, width = 8, height = 6, properties = merge(local.graph, {
      title = "ALB targets"
      stat  = "Minimum"
      metrics = [
        concat([local.elbn, "HealthyHostCount"], local.tg),
        concat([local.elbn, "UnHealthyHostCount"], local.tg, [{ stat = "Maximum" }]),
      ]
    }) },

    # RDS
    { type = "metric", x = 0, y = 21, width = 8, height = 6, properties = merge(local.graph, {
      title   = "RDS CPU (%)"
      stat    = "Average"
      yAxis   = { left = { min = 0, max = 100 } }
      metrics = [concat(["AWS/RDS", "CPUUtilization"], local.rds)]
    }) },
    { type = "metric", x = 8, y = 21, width = 8, height = 6, properties = merge(local.graph, {
      title   = "RDS connections"
      stat    = "Maximum"
      metrics = [concat(["AWS/RDS", "DatabaseConnections"], local.rds)]
    }) },
    { type = "metric", x = 16, y = 21, width = 8, height = 6, properties = merge(local.graph, {
      title = "RDS free storage (GiB)"
      metrics = [
        [{ expression = "fs / 1073741824", label = "Free storage (GiB)", id = "gib" }],
        concat(["AWS/RDS", "FreeStorageSpace"], local.rds, [{ id = "fs", stat = "Minimum", visible = false }]),
      ]
    }) },

    # Redis
    { type = "metric", x = 0, y = 27, width = 6, height = 6, properties = merge(local.graph, {
      title = "Redis engine CPU (%)", stat = "Average", metrics = local.redis_series.EngineCPUUtilization
    }) },
    { type = "metric", x = 6, y = 27, width = 6, height = 6, properties = merge(local.graph, {
      title = "Redis memory used (%)", stat = "Maximum", metrics = local.redis_series.DatabaseMemoryUsagePercentage
    }) },
    { type = "metric", x = 12, y = 27, width = 6, height = 6, properties = merge(local.graph, {
      title = "Redis connections", stat = "Maximum", metrics = local.redis_series.CurrConnections
    }) },
    { type = "metric", x = 18, y = 27, width = 6, height = 6, properties = merge(local.graph, {
      title = "Redis evictions", stat = "Sum", metrics = local.redis_series.Evictions
    }) },

    # Alarms
    { type = "alarm", x = 0, y = 33, width = 24, height = 6, properties = {
      title  = "Alarms"
      alarms = local.all_alarm_arns
    } },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.deployment_name}-gateway"
  dashboard_body = jsonencode({ widgets = local.widgets })
}
