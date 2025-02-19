# If publicLoadBalancer = true, we fetch the existing public hosted zone
data "aws_route53_zone" "public_zone" {
  count       = var.publicLoadBalancer ? 1 : 0
  name        = var.hostedZoneName
  private_zone = false
}

# If publicLoadBalancer = false, we create a private hosted zone
resource "aws_route53_zone" "private_zone" {
  count = var.publicLoadBalancer ? 0 : 1

  name = var.hostedZoneName
  vpc {
    vpc_id = local.final_vpc_id
  }
}