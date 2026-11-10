# Create-or-bring VPC. Bring-your-own subnets are validated before anything is
# created (vpc-validation.tf). The created VPC spans two Availability Zones;
# in no-internet mode it has no internet gateway, no NAT and no public subnets,
# and AWS services are reached through VPC endpoints only (vpc-endpoints.tf).

locals {
  creating_new_vpc = var.vpc_id == null
  internet_enabled = !var.disable_outbound_network_access

  vpc_id   = local.creating_new_vpc ? aws_vpc.new[0].id : data.aws_vpc.existing[0].id
  vpc_cidr = local.creating_new_vpc ? aws_vpc.new[0].cidr_block : data.aws_vpc.existing[0].cidr_block

  private_subnet_ids = local.creating_new_vpc ? [for s in aws_subnet.private : s.id] : var.private_subnet_ids
  public_subnet_ids  = local.creating_new_vpc ? [for s in aws_subnet.public : s.id] : var.public_subnet_ids

  create_endpoints = local.creating_new_vpc || var.create_vpc_endpoints_in_existing_vpc
  # Interface endpoints are billed per hour and AZ; with egress they are optional.
  create_interface_endpoints = local.create_endpoints && (var.disable_outbound_network_access || var.create_interface_endpoints)
}

data "aws_vpc" "existing" {
  count = local.creating_new_vpc ? 0 : 1
  id    = var.vpc_id
}

data "aws_availability_zones" "available" {
  count = local.creating_new_vpc ? 1 : 0
  state = "available"
}

resource "aws_vpc" "new" {
  count                = local.creating_new_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.deployment_name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count  = local.creating_new_vpc && local.internet_enabled ? 1 : 0
  vpc_id = aws_vpc.new[0].id

  tags = { Name = "${var.deployment_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = local.creating_new_vpc && local.internet_enabled ? 2 : 0
  vpc_id                  = aws_vpc.new[0].id
  cidr_block              = cidrsubnet(aws_vpc.new[0].cidr_block, 3, count.index)
  availability_zone       = data.aws_availability_zones.available[0].names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.deployment_name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count                   = local.creating_new_vpc ? 2 : 0
  vpc_id                  = aws_vpc.new[0].id
  cidr_block              = cidrsubnet(aws_vpc.new[0].cidr_block, 3, count.index + 2)
  availability_zone       = data.aws_availability_zones.available[0].names[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.deployment_name}-private-${count.index}" }
}

# One NAT gateway, in the first public subnet, for outbound traffic from the
# private subnets: the image pull from ghcr.io, the online check of older-format
# licence keys, the IdP, non-Bedrock providers, and AWS service calls unless the
# optional interface endpoints are created. S3 traffic uses the gateway endpoint.
resource "aws_eip" "nat" {
  count  = local.creating_new_vpc && local.internet_enabled ? 1 : 0
  domain = "vpc"

  tags = { Name = "${var.deployment_name}-nat" }
}

resource "aws_nat_gateway" "this" {
  count         = local.creating_new_vpc && local.internet_enabled ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.this]

  tags = { Name = "${var.deployment_name}-nat" }
}

resource "aws_route_table" "public" {
  count  = local.creating_new_vpc && local.internet_enabled ? 1 : 0
  vpc_id = aws_vpc.new[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = { Name = "${var.deployment_name}-public" }
}

resource "aws_route_table" "private" {
  count  = local.creating_new_vpc ? 1 : 0
  vpc_id = aws_vpc.new[0].id

  dynamic "route" {
    for_each = local.internet_enabled ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = { Name = "${var.deployment_name}-private" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# Flow logs for the created VPC. A bring-your-own VPC keeps its owner's flow
# log configuration.
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count             = local.creating_new_vpc ? 1 : 0
  name              = "/aws/vpc/${var.deployment_name}-flow-logs"
  retention_in_days = local.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_flow_log" "this" {
  count                    = local.creating_new_vpc ? 1 : 0
  vpc_id                   = aws_vpc.new[0].id
  log_destination          = aws_cloudwatch_log_group.vpc_flow_logs[0].arn
  log_destination_type     = "cloud-watch-logs"
  iam_role_arn             = aws_iam_role.vpc_flow_logs[0].arn
  traffic_type             = "ALL"
  max_aggregation_interval = 60
}
