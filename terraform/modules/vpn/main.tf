# Optional demo Client VPN (certificate-based mutual TLS). Demo and trial use
# only; use Direct Connect, Transit Gateway or your own VPN for regular access.
#
# Certificates are created and imported into ACM by deploy/setup-vpn.sh so
# that no private key ever passes through Terraform state. One shared client
# certificate, split tunnel, the VPC's DNS, and authorisation to the VPC
# range only.

locals {
  # The VPC DNS resolver always sits at the VPC base address + 2.
  dns_resolver = cidrhost(var.vpc_cidr, 2)
}

resource "aws_cloudwatch_log_group" "vpn" {
  #checkov:skip=CKV_AWS_338:Demo-only endpoint; retention is configurable via log_retention_days (default 3653).
  name              = "/${var.deployment_name}/vpn/connections"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "vpn" {
  name           = "connections"
  log_group_name = aws_cloudwatch_log_group.vpn.name
}

resource "aws_security_group" "vpn" {
  name        = "${var.deployment_name}-client-vpn"
  description = "Client VPN endpoint ENIs for ${var.deployment_name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.deployment_name}-client-vpn"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "vpn_tcp" {
  for_each = toset([for p in var.egress_ports : tostring(p)])

  security_group_id = aws_security_group.vpn.id
  description       = "VPN clients to the VPC on TCP ${each.value}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = var.vpc_cidr
  tags              = var.tags
}

resource "aws_vpc_security_group_egress_rule" "vpn_dns" {
  for_each = toset(["udp", "tcp"])

  security_group_id = aws_security_group.vpn.id
  description       = "VPN clients to the VPC DNS resolver (${each.value})"
  ip_protocol       = each.value
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${local.dns_resolver}/32"
  tags              = var.tags
}

resource "aws_ec2_client_vpn_endpoint" "vpn" {
  description            = "${var.deployment_name} demo Client VPN"
  server_certificate_arn = var.server_certificate_arn
  client_cidr_block      = var.client_cidr
  vpc_id                 = var.vpc_id
  security_group_ids     = [aws_security_group.vpn.id]
  dns_servers            = [local.dns_resolver]
  split_tunnel           = true
  transport_protocol     = "udp"
  vpn_port               = 443
  session_timeout_hours  = var.session_timeout_hours
  self_service_portal    = "disabled"

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.client_root_certificate_arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.vpn.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.vpn.name
  }

  client_login_banner_options {
    enabled     = true
    banner_text = "${var.deployment_name}: demo/test access only."
  }

  tags = merge(var.tags, {
    Name = "${var.deployment_name}-client-vpn"
  })
}

# count (not for_each) so subnet IDs that are unknown until apply still plan.
resource "aws_ec2_client_vpn_network_association" "vpn" {
  count = length(var.subnet_ids)

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.vpn.id
  subnet_id              = var.subnet_ids[count.index]
}

# Associating a subnet adds the VPC CIDR route automatically; only authorise it.
resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.vpn.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "${var.deployment_name} VPC"
}

resource "aws_ssm_parameter" "endpoint_id" {
  #checkov:skip=CKV2_AWS_34:Endpoint ID is a non-secret identifier read by deploy/setup-vpn.sh; String is intentional.
  name        = "/${var.deployment_name}/vpn/endpoint-id"
  description = "Client VPN endpoint ID for ${var.deployment_name} (read by deploy/setup-vpn.sh profile)"
  type        = "String"
  value       = aws_ec2_client_vpn_endpoint.vpn.id
  tags        = var.tags
}
