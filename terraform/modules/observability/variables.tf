variable "deployment_name" {
  description = "Name prefix for every resource created by the module. Must match the root modules' deployment_name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.deployment_name))
    error_message = "deployment_name must start with a lowercase letter and contain only lowercase letters, digits and hyphens (max 20 characters)."
  }
}

variable "tags" {
  description = "Extra tags applied to the module's taggable resources, merged on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Monitored resources
# ---------------------------------------------------------------------------

variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB in front of LiteLLM (aws_lb.arn_suffix, e.g. app/my-alb/0123456789abcdef). Used as the LoadBalancer dimension."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "ARN suffix of the LiteLLM target group (aws_lb_target_group.arn_suffix, e.g. targetgroup/my-tg/0123456789abcdef). Used as the TargetGroup dimension."
  type        = string
}

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster running LiteLLM. Container Insights must be enabled on it for the running-task alarm."
  type        = string
}

variable "ecs_service_name" {
  description = "Name of the LiteLLM ECS service."
  type        = string
}

variable "rds_instance_identifier" {
  description = "Identifier of the RDS PostgreSQL instance (DBInstanceIdentifier dimension)."
  type        = string
}

variable "redis_replication_group_id" {
  description = "ID of the ElastiCache Redis replication group (cluster mode disabled). ElastiCache publishes node metrics per CacheClusterId, so member cluster IDs are derived as <id>-001, <id>-002, ... unless redis_cache_cluster_ids is set."
  type        = string
}

variable "redis_num_cache_clusters" {
  description = "Number of cache clusters (nodes) in the replication group; used to derive the member CacheClusterIds. With a single node the replication-lag alarm is not created."
  type        = number
  default     = 2

  validation {
    condition     = var.redis_num_cache_clusters >= 1 && var.redis_num_cache_clusters <= 6
    error_message = "redis_num_cache_clusters must be between 1 and 6."
  }
}

variable "redis_cache_cluster_ids" {
  description = "Explicit list of member CacheClusterIds to monitor. Overrides the IDs derived from redis_replication_group_id. Values must be known at plan time."
  type        = list(string)
  default     = null
}

variable "log_group_name" {
  description = "Name of the CloudWatch log group receiving the LiteLLM container logs (JSON_LOGS=True). Required when enable_log_metrics is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_log_metrics || var.log_group_name != null
    error_message = "log_group_name is required when enable_log_metrics is true."
  }
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

variable "alarm_sns_topic_arn" {
  description = "Existing SNS topic for alarm and OK notifications. When null, the module creates a KMS-encrypted topic."
  type        = string
  default     = null
}

variable "alarm_email" {
  description = "Optional email address subscribed to the alarm topic (the subscription must be confirmed from the email)."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for the module-created SNS topic. Its key policy must allow cloudwatch.amazonaws.com kms:Decrypt and kms:GenerateDataKey*. When null, the module creates a dedicated key."
  type        = string
  default     = null
}

variable "alarm_actions_enabled" {
  description = "Whether alarms send notifications to the SNS topic."
  type        = bool
  default     = true
}

variable "enable_log_metrics" {
  description = "Create a CloudWatch Logs metric filter (and alarm) counting LiteLLM ERROR log lines in log_group_name."
  type        = bool
  default     = true
}

variable "log_metric_namespace" {
  description = "CloudWatch namespace for the log-derived metric. Defaults to LiteLLM/<deployment_name>."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------

variable "alarm_period_seconds" {
  description = "Period in seconds for all alarms."
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 300, 900, 3600], var.alarm_period_seconds)
    error_message = "alarm_period_seconds must be one of 60, 300, 900 or 3600."
  }
}

variable "error_rate_threshold_percent" {
  description = "Alarm when ALB target 5XX responses exceed this percentage of requests."
  type        = number
  default     = 5
}

variable "error_rate_min_requests" {
  description = "Minimum requests per period before the error-rate alarm evaluates (avoids alarming on 1 failed request out of 1)."
  type        = number
  default     = 10
}

variable "elb_5xx_threshold" {
  description = "Alarm when the ALB itself returns more than this many 5XX responses per period (no healthy targets, timeouts, etc.)."
  type        = number
  default     = 10
}

# LLM responses, streamed ones included, are measured by the ALB until the last
# byte and routinely take tens of seconds, so a gateway-style threshold (a few
# seconds) would keep this alarm red. 60 s catches stuck or saturated targets;
# the 5XX alarms remain the primary failure signal.
variable "latency_p90_threshold_seconds" {
  description = "Alarm when p90 TargetResponseTime exceeds this many seconds. Streaming responses count until the last byte, so keep this above your typical generation time."
  type        = number
  default     = 60

  validation {
    condition     = var.latency_p90_threshold_seconds > 0
    error_message = "latency_p90_threshold_seconds must be greater than 0."
  }
}

variable "ecs_cpu_threshold_percent" {
  description = "Alarm when average ECS service CPU utilization exceeds this percentage."
  type        = number
  default     = 80
}

variable "ecs_memory_threshold_percent" {
  description = "Alarm when average ECS service memory utilization exceeds this percentage."
  type        = number
  default     = 80
}

variable "rds_cpu_threshold_percent" {
  description = "Alarm when RDS CPUUtilization exceeds this percentage."
  type        = number
  default     = 80
}

variable "rds_free_storage_threshold_gib" {
  description = "Alarm when RDS FreeStorageSpace drops below this many GiB."
  type        = number
  default     = 5
}

# 20 tasks x ~10 pooled connections each (LiteLLM's default pool) x 2 while a
# rolling deploy runs old and new tasks = ~400, plus the migration task and
# admin sessions: 450. db.t4g.large allows ~880 (RDS PostgreSQL default
# max_connections for 8 GiB), so the alarm fires with headroom left.
variable "rds_connections_threshold" {
  description = "Alarm when RDS DatabaseConnections exceeds this value. The default fits 20 tasks during a rolling deploy on db.t4g.large; scale it with max_capacity and the instance class."
  type        = number
  default     = 450
}

variable "redis_engine_cpu_threshold_percent" {
  description = "Alarm when ElastiCache EngineCPUUtilization on any node exceeds this percentage."
  type        = number
  default     = 80
}

variable "redis_memory_threshold_percent" {
  description = "Alarm when ElastiCache DatabaseMemoryUsagePercentage on any node exceeds this percentage."
  type        = number
  default     = 80
}

variable "redis_connections_threshold" {
  description = "Alarm when ElastiCache CurrConnections on any node exceeds this value."
  type        = number
  default     = 5000
}

variable "redis_replication_lag_threshold_seconds" {
  description = "Alarm when ElastiCache ReplicationLag on any replica exceeds this many seconds (only created with 2+ nodes)."
  type        = number
  default     = 10
}

variable "log_error_threshold" {
  description = "Alarm when LiteLLM logs more than this many ERROR lines per period. Client auth failures are also logged at ERROR."
  type        = number
  default     = 50
}
