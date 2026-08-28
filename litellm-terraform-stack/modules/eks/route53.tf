
# Only lookup the Route53 zone if hosted_zone_name is provided
data "aws_route53_zone" "selected" {
  count        = var.hosted_zone_name != "" ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = var.public_load_balancer ? false : true
}


# Only create the A record if hosted_zone_name is provided
resource "aws_route53_record" "litellm" {
  count   = var.hosted_zone_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.selected[0].zone_id
  name    = var.record_name  # e.g., "litellm.mirodrr.people.aws.dev"
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress_alb.dns_name
    zone_id                = data.aws_lb.ingress_alb.zone_id
    evaluate_target_health = true
  }

  depends_on = [kubernetes_ingress_v1.litellm]
}
