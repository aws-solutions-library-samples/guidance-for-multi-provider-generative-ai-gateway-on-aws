# If publicLoadBalancer = true, we fetch the existing public hosted zone
data "aws_route53_zone" "public_zone" {
  count       = var.publicLoadBalancer ? 1 : 0
  name        = var.hostedZoneName
  private_zone = false
}

locals {
  create_private_load_balancer = var.publicLoadBalancer ? false : local.creating_new_vpc || var.create_private_hosted_zone_in_existing_vpc ? true : false
  import_private_load_balancer = var.publicLoadBalancer ? false : local.creating_new_vpc || var.create_private_hosted_zone_in_existing_vpc ? false : true
}

resource "aws_route53_zone" "new_private_zone" {
  //If public load balancer, never create private zone
  //If private load balancer, always create private zone if we are creating new vpc
  //If private load balancer, and user brings their own vpc, decide whether to create or import private hosted zone based on "var.create_private_hosted_zone_in_existing_vpc" variable
  count = local.create_private_load_balancer ? 1 : 0
  name = var.hostedZoneName
  vpc {
    vpc_id = local.final_vpc_id
  }
}

data "aws_route53_zone" "existing_private_zone" {
  //If public load balancer, never create private zone
  //If private load balancer, always create private zone if we are creating new vpc
  //If private load balancer, and user brings their own vpc, decide whether to create or import private hosted zone based on "var.create_private_hosted_zone_in_existing_vpc" variable
  count = local.import_private_load_balancer ? 1 : 0
  name = var.hostedZoneName
  private_zone = true
}
