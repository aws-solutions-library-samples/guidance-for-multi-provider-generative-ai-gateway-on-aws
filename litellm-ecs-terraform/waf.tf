###############################################################################
# (10) WAFv2 Web ACL Association
###############################################################################
resource "aws_wafv2_web_acl_association" "litellm_waf" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.wafv2_acl_arn
}