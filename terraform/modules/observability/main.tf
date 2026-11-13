data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  create_topic   = var.alarm_sns_topic_arn == null
  create_kms_key = local.create_topic && var.kms_key_arn == null
  sns_topic_arn  = local.create_topic ? aws_sns_topic.alarms[0].arn : var.alarm_sns_topic_arn

  # Node metrics (EngineCPUUtilization, Evictions, CurrConnections, ReplicationLag, ...) are only
  # published per CacheClusterId. Member clusters of a cluster-mode-disabled replication group are
  # named <replication_group_id>-001, -002, ...
  redis_cache_cluster_ids = coalesce(
    var.redis_cache_cluster_ids,
    [for i in range(var.redis_num_cache_clusters) : format("%s-%03d", var.redis_replication_group_id, i + 1)]
  )

  log_metric_namespace = coalesce(var.log_metric_namespace, "LiteLLM/${var.deployment_name}")
  log_error_metric     = "LogErrorCount"

  alb_dims = { LoadBalancer = var.alb_arn_suffix }
  tg_dims  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  ecs_dims = { ClusterName = var.ecs_cluster_name, ServiceName = var.ecs_service_name }
  rds_dims = { DBInstanceIdentifier = var.rds_instance_identifier }
}

# ---------------------------------------------------------------------------
# Alarm topic (only when the caller does not bring one)
# ---------------------------------------------------------------------------

# The AWS managed alias/aws/sns key cannot be used: CloudWatch needs kms:GenerateDataKey* on the
# key to publish to an encrypted topic, which only a customer managed key policy can grant.
data "aws_iam_policy_document" "alarms_kms" {
  count = local.create_kms_key ? 1 : 0

  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"] # in a key policy, resource "*" refers only to this key
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "alarms" {
  count = local.create_kms_key ? 1 : 0

  description             = "${var.deployment_name} alarm SNS topic"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.alarms_kms[0].json
  tags                    = var.tags
}

resource "aws_kms_alias" "alarms" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/${var.deployment_name}-alarms"
  target_key_id = aws_kms_key.alarms[0].key_id
}

resource "aws_sns_topic" "alarms" {
  count = local.create_topic ? 1 : 0

  name              = "${var.deployment_name}-alarms"
  kms_master_key_id = local.create_kms_key ? aws_kms_key.alarms[0].arn : var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "alarms_topic" {
  count = local.create_topic ? 1 : 0

  statement {
    sid = "AccountOwner"
    actions = [
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish",
    ]
    resources = [aws_sns_topic.alarms[0].arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms[0].arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  count = local.create_topic ? 1 : 0

  arn    = aws_sns_topic.alarms[0].arn
  policy = data.aws_iam_policy_document.alarms_topic[0].json
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != null ? 1 : 0

  topic_arn = local.sns_topic_arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
