data "aws_vpc" "existing" {
  count = length(trimspace(var.vpc_id)) > 0 ? 1 : 0
  id    = var.vpc_id
}

# We'll expose a local reference to either the existing VPC or a newly created one:
resource "aws_vpc" "new" {
  count             = length(trimspace(var.vpc_id)) == 0 ? 1 : 0
  cidr_block        = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# We create an Internet Gateway only if we're creating the new VPC
resource "aws_internet_gateway" "this" {
  count = length(trimspace(var.vpc_id)) == 0 ? 1 : 0
  vpc_id = aws_vpc.new[0].id
}

# Create the NAT gateway only if nat_gateway_count = 1 (and we have a new VPC).
# We'll put it in the first public subnet for simplicity.
resource "aws_eip" "nat" {
  count = (length(trimspace(var.vpc_id)) == 0 && local.nat_gateway_count == 1) ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  count         = (length(trimspace(var.vpc_id)) == 0 && local.nat_gateway_count == 1) ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_subnet" "public" {
  count             = (length(trimspace(var.vpc_id)) == 0) ? 2 : 0
  vpc_id            = aws_vpc.new[0].id
  cidr_block        = cidrsubnet(aws_vpc.new[0].cidr_block, 3, count.index)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = (length(trimspace(var.vpc_id)) == 0) ? 2 : 0
  vpc_id            = aws_vpc.new[0].id
  cidr_block        = cidrsubnet(aws_vpc.new[0].cidr_block, 3, count.index + 2)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = false
}

# Route tables: one for public subnets, one for private/isolated subnets.
resource "aws_route_table" "public" {
  count = (length(trimspace(var.vpc_id)) == 0) ? 1 : 0
  vpc_id = aws_vpc.new[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
}

resource "aws_route_table" "private" {
  count = (length(trimspace(var.vpc_id)) == 0) ? 1 : 0
  vpc_id = aws_vpc.new[0].id
  # If nat_gateway_count = 1, route to NAT. If 0, no routes => isolated.
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = local.nat_gateway_count == 1 ? aws_nat_gateway.this[0].id : null
  }
  # If nat_gateway_count = 0, no route block is effectively created => Isolated subnets
  # (One can conditionally omit the route block with a dynamic block.)
  lifecycle {
    ignore_changes = [route]
  }
}

# Subnet associations
resource "aws_route_table_association" "public" {
  count = (length(trimspace(var.vpc_id)) == 0) ? length(aws_subnet.public) : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count = (length(trimspace(var.vpc_id)) == 0) ? length(aws_subnet.private) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# Data source for availability_zones
data "aws_availability_zones" "available" {
  state = "available"
  # We only need 2 for the new VPC, but we’ll still retrieve them all, just using index=0,1
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count             = (length(trimspace(var.vpc_id)) == 0) ? 1 : 0
  name              = "/aws/vpc/${var.stack_name}-flow-logs"
  retention_in_days = 30
}

resource "aws_flow_log" "this" {
  count = (length(trimspace(var.vpc_id)) == 0) ? 1 : 0
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"
  vpc_id               = aws_vpc.new[0].id
  iam_role_arn         = aws_iam_role.vpc_flow_logs_role[0].arn
  traffic_type         = "ALL"
  max_aggregation_interval = 60
}

# If you have an existing VPC, you might define:
data "aws_subnets" "existing_all" {
  count = length(trimspace(var.vpc_id)) > 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}
