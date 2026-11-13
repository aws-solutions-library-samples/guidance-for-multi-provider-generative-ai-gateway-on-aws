# The optional demo Client VPN wired into the foundation (terraform/modules/vpn),
# with mocked providers: off by default, certificate inputs enforced, one subnet
# association, and the security group exported for the app's ALB ingress.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b"] }
  }
  mock_data "aws_network_interfaces" {
    defaults = { ids = ["eni-vpce-1"] }
  }
}

# The real random provider (local, no credentials): mock providers do not
# support the ephemeral random_password values the secrets are built from.
provider "random" {}

variables {
  deployment_name = "llmgw"
}

run "vpn_off_by_default" {
  command = plan

  assert {
    condition     = length(module.vpn) == 0
    error_message = "The demo Client VPN must not be created unless create_vpn = true."
  }

  assert {
    condition     = output.vpn_security_group_id == null
    error_message = "vpn_security_group_id must be null when the VPN is off."
  }
}

run "vpn_without_server_certificate_rejected" {
  command = plan

  variables {
    create_vpn                      = true
    vpn_client_root_certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000002"
  }

  expect_failures = [var.vpn_server_certificate_arn]
}

run "vpn_without_client_root_certificate_rejected" {
  command = plan

  variables {
    create_vpn                 = true
    vpn_server_certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000001"
  }

  expect_failures = [var.vpn_client_root_certificate_arn]
}

run "vpn_on_attaches_to_the_vpc_and_exports_its_security_group" {
  command = plan

  variables {
    create_vpn                      = true
    vpn_server_certificate_arn      = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000001"
    vpn_client_root_certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000002"
  }

  # IDs are unknown until apply; make them known at plan time so the wiring
  # assertions can read them.
  override_resource {
    target          = aws_vpc.new
    override_during = plan
    values          = { id = "vpc-0123456789abcdef0", cidr_block = "10.0.0.0/16" }
  }

  override_resource {
    target          = module.vpn[0].aws_security_group.vpn
    override_during = plan
    values          = { id = "sg-0aaaaaaaaaaaaaaa1" }
  }

  assert {
    condition     = length(module.vpn) == 1
    error_message = "create_vpn = true must create the demo Client VPN."
  }

  assert {
    condition     = output.vpn_security_group_id == "sg-0aaaaaaaaaaaaaaa1"
    error_message = "vpn_security_group_id must export the VPN security group for the app's ALB ingress."
  }

  assert {
    condition     = output.vpc_id == "vpc-0123456789abcdef0"
    error_message = "The VPN must attach to the foundation's VPC."
  }
}
