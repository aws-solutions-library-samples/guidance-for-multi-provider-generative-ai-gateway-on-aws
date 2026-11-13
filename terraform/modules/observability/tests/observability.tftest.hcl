# Validation rules and key wiring of the observability module, run against mocked providers.

mock_provider "aws" {
  # The mocked data source would return a random string for `json`, which the
  # aws_kms_key / aws_sns_topic_policy JSON validation rejects.
  override_data {
    target = data.aws_iam_policy_document.alarms_kms
    values = { json = "{}" }
  }
  override_data {
    target = data.aws_iam_policy_document.alarms_topic
    values = { json = "{}" }
  }

  # Mocked computed ARNs are random strings; downstream resources (topic policy,
  # alarm actions) validate ARN syntax, so give the two referenced ones real shapes.
  override_resource {
    target = aws_sns_topic.alarms
    values = { arn = "arn:aws:sns:eu-west-1:111111111111:llmgw-alarms" }
  }
  override_resource {
    target = aws_kms_key.alarms
    values = { arn = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-00000000mock" }
  }
}

variables {
  deployment_name            = "llmgw"
  alb_arn_suffix             = "app/llmgw-alb/0123456789abcdef"
  target_group_arn_suffix    = "targetgroup/llmgw-tg/0123456789abcdef"
  ecs_cluster_name           = "llmgw-cluster"
  ecs_service_name           = "llmgw-litellm"
  rds_instance_identifier    = "llmgw-db"
  redis_replication_group_id = "llmgw-redis"
  log_group_name             = "/ecs/llmgw-litellm"
}

# ---------------------------------------------------------------------------
# Defaults: full alarm set, encrypted topic, dashboard
# ---------------------------------------------------------------------------

run "defaults_create_full_alarm_set" {
  command = apply

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.simple) == 10
    error_message = "Expected 10 single-metric alarms (ALB x4, ECS x2, RDS x3, log errors) at defaults."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.math) == 7
    error_message = "Expected 7 metric-math alarms (5XX rate, running tasks, Redis x5 incl. replication lag) at defaults."
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.errors) == 1
    error_message = "Expected the LiteLLM ERROR log metric filter at defaults."
  }

  assert {
    condition     = length(aws_sns_topic.alarms) == 1 && length(aws_kms_key.alarms) == 1
    error_message = "Expected a module-created SNS topic encrypted with a module-created KMS key at defaults."
  }

  assert {
    condition     = aws_sns_topic.alarms[0].kms_master_key_id == aws_kms_key.alarms[0].arn
    error_message = "The module-created topic must be encrypted with the module-created KMS key."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "No email subscription expected when alarm_email is null."
  }
}

run "names_derive_from_deployment_name" {
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["alb-elb-5xx"].alarm_name == "llmgw-alb-elb-5xx"
    error_message = "Simple alarm names must be prefixed with deployment_name."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.math["alb-target-5xx-rate"].alarm_name == "llmgw-alb-target-5xx-rate"
    error_message = "Math alarm names must be prefixed with deployment_name."
  }

  assert {
    condition     = aws_cloudwatch_dashboard.this.dashboard_name == "llmgw-gateway"
    error_message = "Dashboard name must derive from deployment_name."
  }

  assert {
    condition     = aws_sns_topic.alarms[0].name == "llmgw-alarms"
    error_message = "SNS topic name must derive from deployment_name."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.errors[0].name == "llmgw-log-errors"
    error_message = "Log metric filter name must derive from deployment_name."
  }
}

run "dashboard_has_18_widgets_and_all_alarms" {
  command = apply

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets) == 18
    error_message = "Expected an 18-widget dashboard at defaults."
  }

  assert {
    condition     = length([for w in jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets : w if w.type == "alarm"][0].properties.alarms) == 17
    error_message = "The alarm-status widget must list all 17 alarms created at defaults."
  }
}

run "alarms_notify_topic_on_alarm_and_ok" {
  command = apply

  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.simple :
      contains(a.alarm_actions, aws_sns_topic.alarms[0].arn) && contains(a.ok_actions, aws_sns_topic.alarms[0].arn)
    ])
    error_message = "Every simple alarm must notify the module topic on ALARM and OK."
  }

  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.math :
      contains(a.alarm_actions, aws_sns_topic.alarms[0].arn) && contains(a.ok_actions, aws_sns_topic.alarms[0].arn)
    ])
    error_message = "Every math alarm must notify the module topic on ALARM and OK."
  }
}

run "alarm_dimensions_wired_from_inputs" {
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["alb-elb-5xx"].dimensions["LoadBalancer"] == "app/llmgw-alb/0123456789abcdef"
    error_message = "ALB alarms must use alb_arn_suffix as the LoadBalancer dimension."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["alb-latency-p90"].dimensions["TargetGroup"] == "targetgroup/llmgw-tg/0123456789abcdef"
    error_message = "Target-group alarms must use target_group_arn_suffix as the TargetGroup dimension."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["ecs-cpu-high"].dimensions["ClusterName"] == "llmgw-cluster" && aws_cloudwatch_metric_alarm.simple["ecs-cpu-high"].dimensions["ServiceName"] == "llmgw-litellm"
    error_message = "ECS alarms must use ecs_cluster_name and ecs_service_name as dimensions."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["rds-cpu-high"].dimensions["DBInstanceIdentifier"] == "llmgw-db"
    error_message = "RDS alarms must use rds_instance_identifier as the DBInstanceIdentifier dimension."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.errors[0].log_group_name == "/ecs/llmgw-litellm"
    error_message = "The log metric filter must target log_group_name."
  }

  assert {
    condition     = output.redis_cache_cluster_ids == tolist(["llmgw-redis-001", "llmgw-redis-002"])
    error_message = "Member CacheClusterIds must be derived as <replication_group_id>-001, -002 by default."
  }
}

# ---------------------------------------------------------------------------
# Notification plumbing variants
# ---------------------------------------------------------------------------

run "existing_topic_creates_no_topic_or_key" {
  command = apply

  variables {
    alarm_sns_topic_arn = "arn:aws:sns:eu-west-1:111111111111:existing-alarms"
  }

  assert {
    condition     = length(aws_sns_topic.alarms) == 0 && length(aws_kms_key.alarms) == 0 && length(aws_sns_topic_policy.alarms) == 0
    error_message = "No topic, key or topic policy may be created when alarm_sns_topic_arn is passed."
  }

  assert {
    condition     = output.sns_topic_arn == "arn:aws:sns:eu-west-1:111111111111:existing-alarms"
    error_message = "The passed-in topic must be the one alarms notify."
  }

  assert {
    condition     = contains(aws_cloudwatch_metric_alarm.simple["rds-cpu-high"].alarm_actions, "arn:aws:sns:eu-west-1:111111111111:existing-alarms")
    error_message = "Alarms must notify the passed-in topic."
  }

  assert {
    condition     = output.kms_key_arn == null
    error_message = "kms_key_arn output must be null when no key is created."
  }
}

run "caller_kms_key_used_instead_of_creating_one" {
  command = apply

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = length(aws_kms_key.alarms) == 0
    error_message = "No KMS key may be created when kms_key_arn is passed."
  }

  assert {
    condition     = aws_sns_topic.alarms[0].kms_master_key_id == "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
    error_message = "The module-created topic must be encrypted with the passed-in key."
  }
}

run "alarm_email_subscribes_to_topic" {
  command = apply

  variables {
    alarm_email = "oncall@example.com"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1 && aws_sns_topic_subscription.email[0].protocol == "email"
    error_message = "alarm_email must create an email subscription on the alarm topic."
  }
}

run "alarm_actions_disabled" {
  command = apply

  variables {
    alarm_actions_enabled = false
  }

  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.simple : a.actions_enabled == false && length(a.alarm_actions) == 0
    ])
    error_message = "With alarm_actions_enabled = false, alarms must not have actions."
  }
}

# ---------------------------------------------------------------------------
# Optional pieces
# ---------------------------------------------------------------------------

run "log_metrics_disabled_drops_filter_and_alarm" {
  command = apply

  variables {
    enable_log_metrics = false
    log_group_name     = null
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.errors) == 0
    error_message = "No log metric filter expected when enable_log_metrics is false."
  }

  assert {
    condition     = !contains(keys(aws_cloudwatch_metric_alarm.simple), "log-errors")
    error_message = "No log-errors alarm expected when enable_log_metrics is false."
  }
}

run "single_redis_node_drops_replication_lag_alarm" {
  command = apply

  variables {
    redis_num_cache_clusters = 1
  }

  assert {
    condition     = !contains(keys(aws_cloudwatch_metric_alarm.math), "redis-replication-lag")
    error_message = "No replication-lag alarm expected with a single Redis node."
  }

  assert {
    condition     = output.redis_cache_cluster_ids == tolist(["llmgw-redis-001"])
    error_message = "A single member CacheClusterId must be derived with one node."
  }
}

run "explicit_redis_cache_cluster_ids_override" {
  command = apply

  variables {
    redis_cache_cluster_ids = ["custom-a", "custom-b", "custom-c"]
  }

  assert {
    condition     = output.redis_cache_cluster_ids == tolist(["custom-a", "custom-b", "custom-c"])
    error_message = "redis_cache_cluster_ids must override the derived member IDs."
  }
}

# ---------------------------------------------------------------------------
# Validation rules (rejected inputs)
# ---------------------------------------------------------------------------

run "log_metrics_without_log_group_rejected" {
  command = plan

  variables {
    log_group_name = null
  }

  expect_failures = [var.log_group_name]
}

run "invalid_deployment_name_rejected" {
  command = plan

  variables {
    deployment_name = "LLM_Gateway"
  }

  expect_failures = [var.deployment_name]
}

run "invalid_alarm_period_rejected" {
  command = plan

  variables {
    alarm_period_seconds = 120
  }

  expect_failures = [var.alarm_period_seconds]
}

run "too_many_redis_nodes_rejected" {
  command = plan

  variables {
    redis_num_cache_clusters = 7
  }

  expect_failures = [var.redis_num_cache_clusters]
}

run "latency_alarm_defaults_to_60_seconds_p90" {
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["alb-latency-p90"].threshold == 60 && aws_cloudwatch_metric_alarm.simple["alb-latency-p90"].extended_statistic == "p90"
    error_message = "The p90 latency alarm must default to 60 s: LLM responses are measured to the last byte and routinely take tens of seconds."
  }
}

run "latency_threshold_override" {
  command = apply

  variables {
    latency_p90_threshold_seconds = 120
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["alb-latency-p90"].threshold == 120
    error_message = "latency_p90_threshold_seconds must set the alarm threshold."
  }
}

run "non_positive_latency_threshold_rejected" {
  command = plan

  variables {
    latency_p90_threshold_seconds = 0
  }

  expect_failures = [var.latency_p90_threshold_seconds]
}

run "rds_connections_alarm_defaults_to_450" {
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.simple["rds-connections-high"].threshold == 450
    error_message = "The RDS connections alarm must default to 450 (20 tasks x ~10 connections x 2 during a deploy, below db.t4g.large's ~880)."
  }
}
