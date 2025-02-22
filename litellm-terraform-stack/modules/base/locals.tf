# The NAT gateway count replicates:
#   natGatewayCount = props.disableOutboundNetworkAccess ? 0 : 1
locals {
  nat_gateway_count = var.disable_outbound_network_access ? 0 : 1

  # We'll create private subnets that route to NAT if NAT is 1, or are isolated if NAT is 0.
  # This helps replicate the concept:
  #   - "PRIVATE_WITH_EGRESS" if outbound is allowed
  #   - "PRIVATE_ISOLATED" if outbound is disabled
  # We'll also create 2 public subnets (to have at least an IGW if NAT is needed),
  # though we only place a NAT in the first one.
}

locals {
  creating_new_vpc = length(trimspace(var.vpc_id)) == 0
  final_vpc_id = local.creating_new_vpc ? aws_vpc.new[0].id : data.aws_vpc.existing[0].id
}

# First get all subnets in the VPC with auto-assign public IP enabled
data "aws_subnets" "public_ip_subnets" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Get route tables for these subnets
data "aws_route_table" "subnet_route_tables" {
  for_each  = toset(data.aws_subnets.public_ip_subnets.ids)
  subnet_id = each.value
}

# Get all subnets with auto-assign public IP disabled
data "aws_subnets" "private_ip_subnets" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  
  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

# Get route tables for these subnets
data "aws_route_table" "private_subnet_route_tables" {
  for_each  = toset(data.aws_subnets.private_ip_subnets.ids)
  subnet_id = each.value
}

locals {
  # For new VPC
  new_private_subnet_ids = flatten([
    for s in aws_subnet.private : s.id
  ])

  new_public_subnet_ids = flatten([
    for s in aws_subnet.public : s.id
  ])

  existing_public_subnet_ids = [
    for subnet_id, rt in data.aws_route_table.subnet_route_tables : subnet_id
    if length([
      for route in rt.routes : route
      if route.gateway_id != null && 
         can(regex("^igw-", route.gateway_id)) && 
         route.cidr_block == "0.0.0.0/0"
    ]) > 0
  ]

  existing_private_subnet_ids = [
    for subnet_id, rt in data.aws_route_table.private_subnet_route_tables : subnet_id
    if length([
      for route in rt.routes : route
      if route.gateway_id != null && 
        can(regex("^igw-", route.gateway_id)) && 
        route.cidr_block == "0.0.0.0/0"
    ]) == 0
  ]

  # The final chosen subnets for "private_with_egress" or "private_isolated" usage.
  # If existing VPC => data subnets (you must do your own filtering in real usage).
  # If new VPC => the private subnets we created.
  chosen_subnet_ids = local.creating_new_vpc ? local.new_private_subnet_ids : local.existing_private_subnet_ids
}

locals {
  create_endpoints = (
    local.creating_new_vpc == 0
    || var.create_vpc_endpoints_in_existing_vpc
  )
}

data "aws_route_tables" "existing_vpc_all" {
  # only do the lookup if var.vpc_id is set
  count = local.creating_new_vpc ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

locals {
  # If we’re using an existing VPC, fetch ALL route table IDs.
  # Otherwise, just pick the new route tables from our resources.
  s3_gateway_route_table_ids = local.creating_new_vpc ? [aws_route_table.public[0].id, local.private_route_table.id] : data.aws_route_tables.existing_vpc_all[0].ids
  private_route_table = local.creating_new_vpc ? (local.nat_gateway_count == 1 ? aws_route_table.private_with_nat[0] : aws_route_table.private_isolated[0]) : (null)

}

data "aws_vpc_endpoint_service" "bedrock_agent" {
  # This service name must match exactly what you used in the resource
  service_name = "com.amazonaws.${data.aws_region.current.name}.bedrock-agent"
}

data "aws_subnet" "chosen_subnets" {
  count  = length(local.chosen_subnet_ids)
  id     = local.chosen_subnet_ids[count.index]
}

locals {
  # A map from subnet_id => availability_zone
  subnet_az_map = { 
    for idx, s in data.aws_subnet.chosen_subnets :
    s.id => s.availability_zone
  }
}

locals {
  # Suppose local.chosen_subnet_ids is the list of subnets you want to use
  # for endpoints in general. We filter them down to only those whose AZ
  # is in the service's list of availability_zones.
  bedrock_agent_compatible_subnets = [
    for subnet_id in local.chosen_subnet_ids : subnet_id 
    if contains(data.aws_vpc_endpoint_service.bedrock_agent.availability_zones, local.subnet_az_map[subnet_id])
  ]
}
