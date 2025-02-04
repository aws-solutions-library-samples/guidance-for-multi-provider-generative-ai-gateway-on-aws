
data "aws_route53_zone" "selected" {
  name = "${join(".", slice(split(".", var.domain_name), 1, length(split(".", var.domain_name))))}"
  private_zone = false
}


# Create the A record
resource "aws_route53_record" "litellm" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = var.domain_name  # e.g., "litellm.mirodrr.people.aws.dev"
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress_alb.dns_name
    zone_id                = data.aws_lb.ingress_alb.zone_id
    evaluate_target_health = true
  }

  depends_on = [kubernetes_ingress_v1.litellm]
}