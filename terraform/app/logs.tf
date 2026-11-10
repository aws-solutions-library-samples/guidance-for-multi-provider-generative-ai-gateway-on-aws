# Log sinks owned by the app: the LiteLLM CloudWatch log group, the ALB access-log
# bucket and the LiteLLM request-log bucket (metadata only — message logging is
# off in the rendered config). Ten-year retention (local.log_retention_days);
# the log group and the buckets are kept on destroy while deletion_protection
# is on.

data "aws_caller_identity" "current" {}

locals {
  # Deterministic names: unique per deployment, account and region, and known at
  # plan time, so the rendered config (and its hash) shows up in the plan diff.
  access_log_bucket_name  = "${var.deployment_name}-alb-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  request_log_bucket_name = "${var.deployment_name}-req-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
}

resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/${var.deployment_name}-litellm"
  retention_in_days = local.log_retention_days
  kms_key_id        = var.kms_key_arn
  # Kept on destroy (removed from state only) while deletion_protection is on.
  skip_destroy = var.deletion_protection
}

# Masks email addresses in the LiteLLM logs (user IDs, key aliases and error
# messages can carry them). CloudWatch requires one Audit and one Deidentify
# statement over the same data identifiers.
locals {
  log_masked_data_identifiers = ["arn:aws:dataprotection::aws:data-identifier/EmailAddress"]
}

resource "aws_cloudwatch_log_data_protection_policy" "litellm" {
  log_group_name = aws_cloudwatch_log_group.litellm.name

  policy_document = jsonencode({
    Name    = "${var.deployment_name}-litellm-data-protection"
    Version = "2021-06-01"
    Statement = [
      {
        Sid            = "Audit"
        DataIdentifier = local.log_masked_data_identifiers
        Operation      = { Audit = { FindingsDestination = {} } }
      },
      {
        Sid            = "Redact"
        DataIdentifier = local.log_masked_data_identifiers
        Operation      = { Deidentify = { MaskConfig = {} } }
      },
    ]
  })
}

# --- ALB access logs. ALB log delivery only supports SSE-S3 (AES256), never KMS. ---

resource "aws_s3_bucket" "access_logs" {
  bucket        = local.access_log_bucket_name
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = local.log_retention_days
    }
  }
}

locals {
  # ALB access-log delivery principals. Regions launched after August 2022
  # accept only the log-delivery service principal; regions launched before
  # accept the per-region ELB account (aws partition; AWS publishes this list
  # and adds no regions to it). The bucket policy grants the service principal
  # always and the ELB account where the region has one.
  legacy_elb_accounts = {
    af-south-1     = "098369216593"
    ap-east-1      = "754344448648"
    ap-northeast-1 = "582318560864"
    ap-northeast-2 = "600734575887"
    ap-northeast-3 = "383597477331"
    ap-south-1     = "718504428378"
    ap-southeast-1 = "114774131450"
    ap-southeast-2 = "783225319266"
    ap-southeast-3 = "589379963580"
    ca-central-1   = "985666609251"
    eu-central-1   = "054676820928"
    eu-north-1     = "897822967062"
    eu-south-1     = "635631232127"
    eu-west-1      = "156460612806"
    eu-west-2      = "652711504416"
    eu-west-3      = "009996457667"
    me-south-1     = "076674570225"
    sa-east-1      = "507241528517"
    us-east-1      = "127311923021"
    us-east-2      = "033677994240"
    us-west-1      = "027434742980"
    us-west-2      = "797873946194"
  }
  legacy_elb_account = lookup(local.legacy_elb_accounts, data.aws_region.current.region, null)
}

# TLS-only bucket; log delivery through the service principal (scoped to this
# account's load balancer named after the deployment) and, in regions launched
# before August 2022, the region's ELB account.
resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "EnforceSSLOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.access_logs.arn,
          "${aws_s3_bucket.access_logs.arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AllowELBLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:elasticloadbalancing:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:loadbalancer/app/${var.deployment_name}-alb/*" }
        }
      }],
      local.legacy_elb_account == null ? [] : [{
        Sid       = "AllowLegacyRegionELBLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.legacy_elb_account}:root" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      }]
    )
  })
}

# --- LiteLLM request logs (the s3 callbacks in the rendered config). ---

resource "aws_s3_bucket" "request_logs" {
  bucket        = local.request_log_bucket_name
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_server_side_encryption_configuration" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "request_logs" {
  bucket                  = aws_s3_bucket.request_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = local.log_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceSSLOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.request_logs.arn,
          "${aws_s3_bucket.request_logs.arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}
