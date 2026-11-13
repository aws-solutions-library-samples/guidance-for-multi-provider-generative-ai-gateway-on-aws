# Validation rules and key wiring, run against a mocked provider (no
# credentials, no AWS).

mock_provider "aws" {}

variables {
  deployment_name             = "llmgw"
  vpc_id                      = "vpc-0123456789abcdef0"
  vpc_cidr                    = "10.0.0.0/16"
  subnet_ids                  = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  server_certificate_arn      = "arn:aws:acm:eu-west-1:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  client_root_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/ffffffff-0000-1111-2222-333333333333"
}

run "valid_defaults_plan" {
  command = plan
}

run "endpoint_is_split_tunnel_mutual_tls_with_vpc_dns" {
  command = plan

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn.split_tunnel == true
    error_message = "The demo VPN must be split tunnel: only VPC traffic goes through it."
  }

  assert {
    condition     = tolist(aws_ec2_client_vpn_endpoint.vpn.dns_servers) == tolist(["10.0.0.2"])
    error_message = "Clients must use the VPC DNS resolver (VPC base address + 2)."
  }

  assert {
    condition     = one(aws_ec2_client_vpn_endpoint.vpn.authentication_options).type == "certificate-authentication"
    error_message = "Authentication must be certificate-based mutual TLS."
  }

  assert {
    condition     = one(aws_ec2_client_vpn_endpoint.vpn.authentication_options).root_certificate_chain_arn == var.client_root_certificate_arn
    error_message = "Client certificates must validate against the imported client root chain."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn.server_certificate_arn == var.server_certificate_arn
    error_message = "The server certificate ARN must be wired through."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn.self_service_portal == "disabled"
    error_message = "The self-service portal must stay disabled (certificate auth; one shared client certificate)."
  }

  assert {
    condition     = one(aws_ec2_client_vpn_endpoint.vpn.client_login_banner_options).enabled == true
    error_message = "The demo/test-only login banner must be enabled."
  }
}

run "connection_logs_enabled_with_retention" {
  command = plan

  variables {
    log_retention_days = 30
  }

  assert {
    condition     = one(aws_ec2_client_vpn_endpoint.vpn.connection_log_options).enabled == true
    error_message = "Connection logging must be enabled."
  }

  assert {
    condition     = one(aws_ec2_client_vpn_endpoint.vpn.connection_log_options).cloudwatch_log_group == "/llmgw/vpn/connections"
    error_message = "Connection logs must go to the module's own log group."
  }

  assert {
    condition     = aws_cloudwatch_log_group.vpn.retention_in_days == 30
    error_message = "log_retention_days must set the log group retention."
  }
}

run "authorisation_covers_vpc_range_only" {
  command = plan

  assert {
    condition     = aws_ec2_client_vpn_authorization_rule.vpc.target_network_cidr == var.vpc_cidr
    error_message = "The only authorisation rule must target the VPC CIDR."
  }

  assert {
    condition     = aws_ec2_client_vpn_authorization_rule.vpc.authorize_all_groups == true
    error_message = "Certificate auth has no user groups; the single rule must authorise all."
  }
}

run "security_group_egress_restricted_to_vpc_and_dns" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_egress_rule.vpn_tcp["443"].cidr_ipv4 == var.vpc_cidr
    error_message = "TCP egress must be limited to the VPC CIDR."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.vpn_tcp) == 1
    error_message = "Only the configured egress ports may be opened (default: 443 only)."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_egress_rule.vpn_dns : r.cidr_ipv4 == "10.0.0.2/32"
    ])
    error_message = "DNS egress must be limited to the VPC resolver address."
  }
}

run "names_and_ssm_parameter_derive_from_deployment_name" {
  command = plan

  assert {
    condition     = aws_security_group.vpn.name == "llmgw-client-vpn"
    error_message = "The security group name must derive from deployment_name."
  }

  assert {
    condition     = aws_ssm_parameter.endpoint_id.name == "/llmgw/vpn/endpoint-id"
    error_message = "deploy/setup-vpn.sh reads /<deployment_name>/vpn/endpoint-id; the parameter name must match."
  }
}

run "one_network_association_per_subnet" {
  command = plan

  assert {
    condition     = length(aws_ec2_client_vpn_network_association.vpn) == length(var.subnet_ids)
    error_message = "Every given subnet must be associated with the endpoint."
  }
}

run "extra_egress_port_accepted" {
  command = plan

  variables {
    egress_ports = [443, 80]
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.vpn_tcp) == 2
    error_message = "Each configured egress port must get its own rule."
  }
}

run "invalid_vpc_cidr_rejected" {
  command = plan

  variables {
    vpc_cidr = "not-a-cidr"
  }

  expect_failures = [var.vpc_cidr]
}

run "empty_subnet_ids_rejected" {
  command = plan

  variables {
    subnet_ids = []
  }

  expect_failures = [var.subnet_ids]
}

run "client_cidr_prefix_out_of_aws_range_rejected" {
  command = plan

  variables {
    client_cidr = "10.250.0.0/24"
  }

  expect_failures = [var.client_cidr]
}

run "client_cidr_overlapping_vpc_rejected" {
  command = plan

  variables {
    client_cidr = "10.0.4.0/22"
  }

  expect_failures = [var.client_cidr]
}

run "vpc_inside_client_cidr_rejected" {
  command = plan

  variables {
    vpc_cidr    = "10.250.1.0/24"
    client_cidr = "10.250.0.0/22"
  }

  expect_failures = [var.client_cidr]
}

run "non_acm_server_certificate_arn_rejected" {
  command = plan

  variables {
    server_certificate_arn = "arn:aws:iam::123456789012:server-certificate/foo"
  }

  expect_failures = [var.server_certificate_arn]
}

run "invalid_session_timeout_rejected" {
  command = plan

  variables {
    session_timeout_hours = 6
  }

  expect_failures = [var.session_timeout_hours]
}

run "unsupported_log_retention_rejected" {
  command = plan

  variables {
    log_retention_days = 42
  }

  expect_failures = [var.log_retention_days]
}

run "uppercase_deployment_name_rejected" {
  command = plan

  variables {
    deployment_name = "LLMGateway"
  }

  expect_failures = [var.deployment_name]
}

run "connection_logs_keep_ten_years_by_default" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_group.vpn.retention_in_days == 3653
    error_message = "VPN connection logs default to the ten-year (3653-day) retention."
  }
}
