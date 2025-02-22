
data "aws_route53_zone" "selected" {
  name = var.hosted_zone_name
  private_zone = var.public_load_balancer ? false : true
}


# Create the A record
resource "aws_route53_record" "litellm" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = var.record_name  # e.g., "litellm.mirodrr.people.aws.dev"
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress_alb.dns_name
    zone_id                = data.aws_lb.ingress_alb.zone_id
    evaluate_target_health = true
  }

  depends_on = [kubernetes_ingress_v1.litellm]
}