###############################################################################
# WAFv2 Web ACL
###############################################################################
resource "aws_wafv2_web_acl" "litellm_waf" {
  name        = "LiteLLMWAF"
  description = "WAF for LiteLLM"
  scope       = "REGIONAL" # or CLOUDFRONT

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "LiteLLMWebAcl"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet-Exclusions"
    priority = 1

    # override_action is required if referencing a rule group
    # - use 'none' if you want to keep the group’s default action 
    # - or 'count' to effectively “disable” or “exclude” from blocking
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # This is the Terraform equivalent to the "excludedRules" from CloudFormation/CDK:
        # We override the action of these specific sub-rules to avoid them blocking requests.
        rule_action_override {
          name = "NoUserAgent_HEADER"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "LiteLLMCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }
}
