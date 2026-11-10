# WAF, public mode only: managed common rules, known bad inputs, IP
# reputation and a per-IP rate limit. Requests are logged to CloudWatch so rule
# matches (and false positives) can be triaged.

locals {
  # Per source IP and 5 minutes; LiteLLM's own per-key and per-team limits still
  # apply. Clients behind one corporate NAT share an address, so a tighter
  # limit would throttle whole offices.
  waf_rate_limit_per_5_min = 2000

  # Common rule set rules that inspect the request body or file extensions, set
  # to count-only: prompts routinely contain HTML/JS, file paths, URLs such as
  # the instance-metadata address and file names, and exceed the 8 KB body-size
  # limit. Rules inspecting the URI, query string and headers keep blocking.
  waf_count_only_rules = [
    "SizeRestrictions_BODY",
    "CrossSiteScripting_BODY",
    "GenericLFI_BODY",
    "GenericRFI_BODY",
    "EC2MetaDataSSRF_BODY",
    "RestrictedExtensions_URIPATH",
    "RestrictedExtensions_QUERYARGUMENTS",
  ]
}

resource "aws_wafv2_web_acl" "this" {
  count       = var.public_mode ? 1 : 0
  name        = "${var.deployment_name}-waf"
  description = "WAF for the ${var.deployment_name} LiteLLM gateway"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.deployment_name}WebAcl"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # API clients legitimately send no User-Agent.
        rule_action_override {
          name = "NoUserAgent_HEADER"
          action_to_use {
            count {}
          }
        }

        dynamic "rule_action_override" {
          for_each = local.waf_count_only_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.deployment_name}CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.deployment_name}KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.deployment_name}IpReputation"
      sampled_requests_enabled   = true
    }
  }

  # Per-source-IP flood protection; LiteLLM's own limits still apply per key and team.
  rule {
    name     = "RateLimitPerIp"
    priority = 4

    # 429, not 403: SDKs back off and retry on 429 but treat 403 as a permanent
    # authorization failure.
    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = local.waf_rate_limit_per_5_min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.deployment_name}RateLimitPerIp"
      sampled_requests_enabled   = true
    }
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.public_mode ? 1 : 0
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}

# WAF requires the log group name to start with aws-waf-logs-. Credentials are
# redacted: API keys travel in these headers, the ALB sign-in session in cookies.
resource "aws_cloudwatch_log_group" "waf" {
  count             = var.public_mode ? 1 : 0
  name              = "aws-waf-logs-${var.deployment_name}"
  retention_in_days = local.log_retention_days
  kms_key_id        = var.kms_key_arn
  # Kept on destroy (removed from state only) while deletion_protection is on.
  skip_destroy = var.deletion_protection
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.public_mode ? 1 : 0
  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  dynamic "redacted_fields" {
    for_each = ["authorization", "x-litellm-api-key", "api-key", "cookie"]
    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }
}

