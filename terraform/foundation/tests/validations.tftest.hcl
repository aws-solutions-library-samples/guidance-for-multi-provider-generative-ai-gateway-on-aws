# Input validation rules, run against mocked providers (no credentials, no AWS).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
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

run "valid_defaults_plan" {
  command = plan
}

run "tracking_stack_carries_solution_id_and_deployment_name" {
  command = plan

  assert {
    condition     = aws_cloudformation_stack.guidance_deployment_metrics.name == "llmgw-tracking-stack"
    error_message = "The tracking stack name must derive from deployment_name so two deployments in one account do not collide."
  }

  assert {
    condition     = strcontains(aws_cloudformation_stack.guidance_deployment_metrics.template_body, "SO9022")
    error_message = "The tracking stack must carry solution ID SO9022 in its description."
  }
}

run "uppercase_deployment_name_rejected" {
  command = plan

  variables {
    deployment_name = "LLMGateway"
  }

  expect_failures = [var.deployment_name]
}

run "overlong_deployment_name_rejected" {
  command = plan

  variables {
    deployment_name = "a-very-long-deployment-name-over-twenty"
  }

  expect_failures = [var.deployment_name]
}

run "invalid_extra_ingress_cidr_rejected" {
  command = plan

  variables {
    extra_data_ingress_cidrs = ["10.0.0.0/8", "not-a-cidr"]
  }

  expect_failures = [var.extra_data_ingress_cidrs]
}

run "invalid_extra_ingress_security_group_rejected" {
  command = plan

  variables {
    extra_data_ingress_security_group_ids = ["subnet-0123456789abcdef0"]
  }

  expect_failures = [var.extra_data_ingress_security_group_ids]
}

run "valid_extra_ingress_accepted" {
  command = plan

  variables {
    extra_data_ingress_cidrs              = ["10.1.0.0/16"]
    extra_data_ingress_security_group_ids = ["sg-0123456789abcdef0"]
  }
}

# The extra-ingress inputs must be enforced on BOTH data-store security groups
# (the generic hook for non-ECS clients).
run "extra_ingress_enforced_on_rds_and_redis" {
  command = plan

  variables {
    extra_data_ingress_cidrs              = ["10.1.0.0/16", "10.2.0.0/16"]
    extra_data_ingress_security_group_ids = ["sg-0123456789abcdef0"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.db_from_extra_cidr) == 2 && length(aws_vpc_security_group_ingress_rule.redis_from_extra_cidr) == 2
    error_message = "Every extra_data_ingress_cidrs entry must get an ingress rule on both the RDS and the Redis security group."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.db_from_extra_sg) == 1 && length(aws_vpc_security_group_ingress_rule.redis_from_extra_sg) == 1
    error_message = "Every extra_data_ingress_security_group_ids entry must get an ingress rule on both the RDS and the Redis security group."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_extra_sg["sg-0123456789abcdef0"].referenced_security_group_id == "sg-0123456789abcdef0"
    error_message = "The extra security group must be the ingress rule's source."
  }
}

run "data_ingress_sg_is_the_only_standing_db_source" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.db_from_extra_cidr) == 0 && length(aws_vpc_security_group_ingress_rule.db_from_extra_sg) == 0
    error_message = "Without extra ingress inputs, the data-ingress security group must be the only source admitted to RDS."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_data_ingress.from_port == 5432 && aws_vpc_security_group_ingress_rule.redis_from_data_ingress.from_port == 6379
    error_message = "The data-ingress security group must be admitted on the PostgreSQL and Redis ports."
  }
}

run "public_mode_with_no_internet_rejected" {
  command = plan

  variables {
    public_mode                     = true
    disable_outbound_network_access = true
  }

  expect_failures = [var.public_mode]
}

run "hosted_zone_with_created_vpc_rejected" {
  command = plan

  variables {
    hosted_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.hosted_zone_id]
}

run "no_hosted_zone_with_created_vpc_accepted" {
  command = plan

  assert {
    condition     = var.hosted_zone_id == null && length(aws_vpc.new) == 1
    error_message = "A created VPC without a hosted zone must plan."
  }
}

run "byo_vpc_without_subnets_rejected" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.vpc_id]
}

run "created_vpc_with_subnet_list_rejected" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-a", "subnet-b"]
  }

  expect_failures = [var.vpc_id]
}

run "tiny_vpc_cidr_rejected" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/26"
  }

  expect_failures = [var.vpc_cidr]
}
