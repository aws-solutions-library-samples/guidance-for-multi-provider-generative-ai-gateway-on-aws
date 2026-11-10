# Bring-your-own VPC: validate it at plan time, before anything is created
# Hard problems fail the plan (preconditions); soft ones are
# warnings (checks). Nothing here assumes what the client of the data stores
# is — the IP arithmetic speaks of gateway replicas, not ECS tasks.

locals {
  # The largest number of gateway replicas the free-IP check plans for: the
  # app's auto scaling maximum (20 tasks).
  max_gateway_instances = 20

  byo_vpc            = !local.creating_new_vpc
  byo_subnet_ids     = local.byo_vpc ? toset(concat(var.private_subnet_ids, var.public_subnet_ids)) : toset([])
  required_endpoints = ["secretsmanager", "ecr.api", "ecr.dkr", "logs", "sts", "bedrock-runtime"]
}

data "aws_subnet" "byo" {
  for_each = local.byo_subnet_ids
  id       = each.value
}

# A subnet without an explicit route table association uses the VPC's main route table.
data "aws_route_tables" "byo_explicit" {
  for_each = local.byo_subnet_ids
  vpc_id   = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_table" "byo_main" {
  count  = local.byo_vpc ? 1 : 0
  vpc_id = var.vpc_id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

data "aws_route_table" "byo" {
  for_each       = local.byo_subnet_ids
  route_table_id = length(data.aws_route_tables.byo_explicit[each.value].ids) > 0 ? data.aws_route_tables.byo_explicit[each.value].ids[0] : data.aws_route_table.byo_main[0].id
}

locals {
  byo_igw_default_route = {
    for id, rt in data.aws_route_table.byo : id => anytrue([
      for r in rt.routes : r.cidr_block == "0.0.0.0/0" && startswith(coalesce(r.gateway_id, "-"), "igw-")
    ])
  }
  byo_nat_default_route = {
    for id, rt in data.aws_route_table.byo : id => anytrue([
      for r in rt.routes : r.cidr_block == "0.0.0.0/0" && (try(length(r.nat_gateway_id) > 0, false) || try(length(r.transit_gateway_id) > 0, false) || try(length(r.network_interface_id) > 0, false))
    ])
  }

  byo_foreign_subnets = [for id, s in data.aws_subnet.byo : id if s.vpc_id != var.vpc_id]
  byo_private_azs     = distinct([for id in var.private_subnet_ids : try(data.aws_subnet.byo[id].availability_zone, id)])
  byo_public_azs      = distinct([for id in var.public_subnet_ids : try(data.aws_subnet.byo[id].availability_zone, id)])
  byo_not_private     = [for id in var.private_subnet_ids : id if try(data.aws_subnet.byo[id].map_public_ip_on_launch, false) || try(local.byo_igw_default_route[id], false)]
  byo_public_no_igw   = [for id in var.public_subnet_ids : id if !try(local.byo_igw_default_route[id], false)]
  byo_free_ips        = sum(concat([0], [for id in var.private_subnet_ids : try(data.aws_subnet.byo[id].available_ip_address_count, 0)]))
  byo_entry_subnets   = var.public_mode ? length(var.public_subnet_ids) : length(var.private_subnet_ids)
  # Rolling deploys run up to 2x the gateway replicas; the entry point needs about
  # 8 free IPs per subnet; plus one endpoint ENI per service and subnet, RDS
  # (2 for Multi-AZ) and the Redis nodes.
  byo_ips_needed = local.max_gateway_instances * 2 + 8 * local.byo_entry_subnets + length(local.required_endpoints) * length(var.private_subnet_ids) + 2 + local.redis_num_cache_clusters
  byo_has_egress = anytrue([for id in var.private_subnet_ids : try(local.byo_nat_default_route[id], false)])
  byo_vpc_dns_ok = !local.byo_vpc || (try(data.aws_vpc.existing[0].enable_dns_support, false) && try(data.aws_vpc.existing[0].enable_dns_hostnames, false))
}

resource "terraform_data" "vpc_validation" {
  count = local.byo_vpc ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(var.private_subnet_ids) >= 2
      error_message = "With an existing vpc_id, set private_subnet_ids to at least two private subnets in different Availability Zones."
    }
    precondition {
      condition     = length(local.byo_foreign_subnets) == 0
      error_message = "These subnets are not in ${var.vpc_id}: ${join(", ", local.byo_foreign_subnets)}."
    }
    precondition {
      condition     = length(local.byo_private_azs) >= 2
      error_message = "private_subnet_ids must span at least 2 Availability Zones (found: ${join(", ", local.byo_private_azs)})."
    }
    precondition {
      condition     = length(local.byo_not_private) == 0
      error_message = "These private_subnet_ids are not private (internet gateway default route or public IPs on launch): ${join(", ", local.byo_not_private)}."
    }
    precondition {
      condition     = !var.public_mode || (length(local.byo_public_azs) >= 2 && length(local.byo_public_no_igw) == 0)
      error_message = "Public mode needs public_subnet_ids in at least 2 Availability Zones, each with an internet gateway default route. Without one: ${join(", ", local.byo_public_no_igw)}."
    }
    precondition {
      condition     = local.byo_free_ips >= local.byo_ips_needed
      error_message = "The private subnets have ${local.byo_free_ips} free IP addresses; this deployment needs about ${local.byo_ips_needed} (max gateway replicas x 2 for rolling deploys, the entry point, endpoints, RDS, Redis)."
    }
    precondition {
      condition     = local.byo_vpc_dns_ok
      error_message = "The VPC needs DNS support and DNS hostnames enabled (private DNS on the VPC endpoints; the gateway, RDS and Redis sit in private subnets in both modes)."
    }
  }
}

# Warnings only: the plan continues.
check "byo_vpc_ip_headroom" {
  assert {
    condition     = !local.byo_vpc || local.byo_free_ips >= 2 * local.byo_ips_needed
    error_message = "Low IP headroom in the private subnets (${local.byo_free_ips} free, about ${local.byo_ips_needed} needed). Scaling or a second deployment may run out of addresses."
  }
}

check "byo_vpc_egress" {
  assert {
    condition     = !local.byo_vpc || local.byo_has_egress || var.egress_proxy_configured || var.disable_outbound_network_access
    error_message = "No NAT/TGW default route on the private subnets and no HTTPS proxy: the identity provider (SSO/JWT), the online check of older-format LiteLLM licences and non-Bedrock providers will not be reachable. Bedrock works through VPC endpoints, and signed licences are verified offline."
  }
}

locals {
  # Only a bring-your-own VPC whose private subnets have no NAT or Transit
  # Gateway route, and that gets no stack-created interface endpoints, depends on
  # existing endpoints to reach AWS APIs (secrets, image pulls, logs, Bedrock).
  byo_endpoints_needed = local.byo_vpc && !local.create_interface_endpoints && !local.byo_has_egress
}

check "byo_vpc_endpoints" {
  # Interface endpoints are visible as network interfaces of type vpc_endpoint.
  # The plural lookup returns an empty list instead of failing, so the assertion
  # below always runs and prints its own message.
  data "aws_network_interfaces" "vpc_endpoints" {
    filter {
      name   = "vpc-id"
      values = [local.vpc_id]
    }
    filter {
      name   = "interface-type"
      values = ["vpc_endpoint"]
    }
  }

  assert {
    condition     = !local.byo_endpoints_needed || length(data.aws_network_interfaces.vpc_endpoints.ids) > 0
    error_message = "The private subnets of ${coalesce(var.vpc_id, "the VPC")} have no NAT or Transit Gateway default route and the VPC has no interface endpoints, so the gateway tasks cannot reach AWS APIs. Create interface endpoints for ${join(", ", local.required_endpoints)} and the S3 gateway endpoint, or set create_vpc_endpoints_in_existing_vpc and create_interface_endpoints to let this stack create them."
  }
}
