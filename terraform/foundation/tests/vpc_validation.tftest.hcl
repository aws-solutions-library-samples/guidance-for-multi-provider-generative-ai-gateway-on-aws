# Plan-time validation of a bring-your-own VPC, with a mocked AWS provider
# (no credentials, no AWS): every fail and warn rule.
# Run: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-byo", cidr_block = "10.1.0.0/16", enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b"] }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = [] }
  }
  mock_data "aws_route_table" {
    defaults = {
      id     = "rtb-main"
      routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "", nat_gateway_id = "nat-1", transit_gateway_id = "", network_interface_id = "" }]
    }
  }
  mock_data "aws_network_interfaces" {
    defaults = { ids = ["eni-vpce-1"] }
  }
}

# The real random provider (local, no credentials): mock providers do not
# support the ephemeral random_password values the secrets are built from.
provider "random" {}

variables {
  deployment_name                      = "llmgw"
  vpc_id                               = "vpc-byo"
  private_subnet_ids                   = ["subnet-a", "subnet-b"]
  public_subnet_ids                    = []
  public_mode                          = false
  create_vpc_endpoints_in_existing_vpc = true
}

# Two private subnets in two AZs with a NAT route: valid.
override_data {
  target = data.aws_subnet.byo["subnet-a"]
  values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 200 }
}
override_data {
  target = data.aws_subnet.byo["subnet-b"]
  values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 200 }
}

run "valid_private_vpc" {
  command = plan

  assert {
    condition     = length(terraform_data.vpc_validation) == 1
    error_message = "Validation should run for an existing VPC."
  }

  assert {
    condition     = length(aws_vpc.new) == 0 && length(aws_subnet.private) == 0
    error_message = "No VPC or subnets may be created when one is brought."
  }
}

run "hosted_zone_with_byo_vpc_accepted" {
  command = plan

  variables {
    hosted_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = var.hosted_zone_id == "Z0123456789ABCDEFGHIJ" && length(terraform_data.vpc_validation) == 1
    error_message = "A hosted zone with your own VPC and private subnets must plan."
  }
}

run "new_vpc_skips_validation" {
  command = plan

  variables {
    vpc_id             = null
    private_subnet_ids = []
  }

  assert {
    condition     = length(terraform_data.vpc_validation) == 0
    error_message = "No validation expected when the module creates the VPC."
  }
}

run "subnet_in_other_vpc" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-other", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 200 }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "single_az" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 200 }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "private_subnet_with_public_ips" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-a"]
    values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = true, available_ip_address_count = 200 }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "private_subnet_routes_to_igw" {
  command = plan

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-pub", routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-1", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "" }] }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "not_enough_free_ips" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-a"]
    values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 10 }
  }

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 10 }
  }

  expect_failures = [terraform_data.vpc_validation, check.byo_vpc_ip_headroom]
}

run "public_mode_without_public_subnets" {
  command = plan

  variables {
    public_mode = true
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "public_mode_with_public_subnets_in_two_azs" {
  command = plan

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-pa", "subnet-pb"]
  }

  override_data {
    target = data.aws_subnet.byo["subnet-pa"]
    values = { id = "subnet-pa", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = true, available_ip_address_count = 200 }
  }

  override_data {
    target = data.aws_subnet.byo["subnet-pb"]
    values = { id = "subnet-pb", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = true, available_ip_address_count = 200 }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-pa"]
    values = { id = "rtb-pub", routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-1", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "" }] }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-pb"]
    values = { id = "rtb-pub", routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-1", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "" }] }
  }

  assert {
    condition     = length(terraform_data.vpc_validation) == 1
    error_message = "Validation must pass for a correctly laid out public-mode VPC."
  }
}

run "private_mode_needs_vpc_dns" {
  command = plan

  override_data {
    target = data.aws_vpc.existing[0]
    values = { id = "vpc-byo", cidr_block = "10.1.0.0/16", enable_dns_support = true, enable_dns_hostnames = false }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "no_egress_is_a_warning_not_an_error" {
  command = plan

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }

  expect_failures = [check.byo_vpc_egress]
}

run "egress_proxy_silences_the_egress_warning" {
  command = plan

  variables {
    egress_proxy_configured = true
  }

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }
}

# No egress route and no interface endpoints: the tasks cannot reach AWS APIs.
run "missing_endpoints_without_egress_is_a_warning" {
  command = plan

  variables {
    create_vpc_endpoints_in_existing_vpc = false
  }

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }
  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }
  override_data {
    target = data.aws_network_interfaces.vpc_endpoints
    values = { ids = [] }
  }

  expect_failures = [check.byo_vpc_endpoints, check.byo_vpc_egress]
}

# A NAT route reaches AWS APIs without endpoints: no endpoint warning.
run "missing_endpoints_with_nat_egress_is_fine" {
  command = plan

  variables {
    create_vpc_endpoints_in_existing_vpc = false
  }

  override_data {
    target = data.aws_network_interfaces.vpc_endpoints
    values = { ids = [] }
  }
}

# No egress route, but the VPC already has interface endpoints: no warning.
run "existing_endpoints_without_egress_are_fine" {
  command = plan

  variables {
    create_vpc_endpoints_in_existing_vpc = false
    egress_proxy_configured              = true
  }

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }
  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }
}

# The BYO endpoint opt-in creates the S3 gateway endpoint; interface endpoints
# also need create_interface_endpoints (or no-internet mode), so a VPC without
# egress and without them still gets the warning.
run "byo_endpoint_opt_in_without_interface_endpoints_still_warns" {
  command = plan

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }
  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }
  override_data {
    target = data.aws_network_interfaces.vpc_endpoints
    values = { ids = [] }
  }

  expect_failures = [check.byo_vpc_endpoints, check.byo_vpc_egress]
}

run "byo_interface_endpoints_on_request" {
  command = plan

  variables {
    create_interface_endpoints = true
  }

  override_data {
    target = data.aws_network_interfaces.vpc_endpoints
    values = { ids = [] }
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 6 && length(aws_vpc_endpoint.s3_gateway) == 1
    error_message = "With create_interface_endpoints the bring-your-own VPC gets the 6 interface endpoints and the S3 gateway."
  }
}

# DNS is needed in both modes: tasks, endpoints, RDS and Redis are private.
run "public_mode_also_needs_vpc_dns" {
  command = plan

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-pa", "subnet-pb"]
  }

  override_data {
    target = data.aws_vpc.existing[0]
    values = { id = "vpc-byo", cidr_block = "10.1.0.0/16", enable_dns_support = true, enable_dns_hostnames = false }
  }

  expect_failures = [terraform_data.vpc_validation]
}

# The free-IP check plans for 20 gateway replicas (x2 during a rolling deploy):
# 2 x 30 free addresses (60) are short of the ~72 needed.
run "free_ip_check_plans_for_twenty_replicas" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-a"]
    values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 30 }
  }

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 30 }
  }

  expect_failures = [terraform_data.vpc_validation, check.byo_vpc_ip_headroom]
}

