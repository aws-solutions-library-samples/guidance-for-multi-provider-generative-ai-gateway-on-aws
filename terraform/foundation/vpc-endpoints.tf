# VPC endpoints. The S3 gateway endpoint (free) is always created with a new
# VPC, optionally in a bring-your-own VPC. The interface endpoints (billed per
# hour and AZ) are created only in no-internet mode, where the gateway depends
# on them, or on request (create_interface_endpoints). The set matches what a
# private gateway replica needs: secrets, image pulls (a mirrored ECR image),
# logs, STS and Bedrock inference. The Bedrock control-plane endpoint is not
# included: inference only calls bedrock-runtime.

data "aws_region" "current" {}

locals {
  interface_endpoints = local.create_interface_endpoints ? {
    secretsmanager  = "secretsmanager"
    ecr_api         = "ecr.api"
    ecr_dkr         = "ecr.dkr"
    logs            = "logs"
    sts             = "sts"
    bedrock_runtime = "bedrock-runtime"
  } : {}

  s3_gateway_route_table_ids = local.creating_new_vpc ? concat(
    [for rt in aws_route_table.public : rt.id],
    [for rt in aws_route_table.private : rt.id],
  ) : tolist(data.aws_route_tables.existing_vpc_all[0].ids)
}

data "aws_route_tables" "existing_vpc_all" {
  count = local.creating_new_vpc ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

resource "aws_security_group" "vpc_endpoints" {
  count       = local.create_interface_endpoints ? 1 : 0
  name        = "${var.deployment_name}-vpc-endpoints-sg"
  description = "Interface VPC endpoints: HTTPS from inside the VPC"
  vpc_id      = local.vpc_id

  tags = { Name = "${var.deployment_name}-vpc-endpoints-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count             = local.create_interface_endpoints ? 1 : 0
  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from the VPC"
  cidr_ipv4         = local.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "s3_gateway" {
  count             = local.create_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.s3_gateway_route_table_ids

  tags = { Name = "${var.deployment_name}-s3" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoints
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  subnet_ids          = local.private_subnet_ids
  private_dns_enabled = true

  tags = { Name = "${var.deployment_name}-${each.key}" }
}
