# Load-test infrastructure planned against a mocked provider: nothing touches AWS.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "eu-west-1"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock"
    }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:loadbalancer/net/mock/0123456789abcdef"
      dns_name = "mock-fake.elb.eu-west-1.amazonaws.com"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:targetgroup/mock/0123456789abcdef"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:111111111111:log-group:/ecs/mock"
    }
  }
}

variables {
  vpc_id                    = "vpc-0123456789abcdef0"
  subnet_ids                = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  gateway_security_group_id = "sg-0123456789abcdef0"
  gateway_url               = "http://internal-gw.elb.eu-west-1.amazonaws.com"
}

run "defaults" {
  command = apply

  assert {
    condition     = output.fake_api_base == "http://mock-fake.elb.eu-west-1.amazonaws.com/v1"
    error_message = "fake_api_base must be the NLB with the /v1 OpenAI path."
  }
  assert {
    condition     = output.driver_security_group_id == aws_security_group.driver.id
    error_message = "driver_security_group_id must be the driver's security group (for the gateway's client_security_group_ids)."
  }
  assert {
    condition     = aws_lb.fake.internal && aws_lb.fake.load_balancer_type == "network"
    error_message = "The fake upstream must sit behind an internal NLB."
  }
  assert {
    condition = toset([for r in aws_vpc_security_group_ingress_rule.nlb_from_clients : r.referenced_security_group_id]) == toset([
      "sg-0123456789abcdef0", aws_security_group.driver.id,
    ])
    error_message = "Only the gateway tasks and the driver may reach the fake upstream."
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.nlb_from_clients : r.cidr_ipv4 == null])
    error_message = "The fake upstream must not be opened to CIDR ranges."
  }
  assert {
    condition     = aws_instance.driver.metadata_options[0].http_tokens == "required" && aws_instance.driver.associate_public_ip_address != true
    error_message = "The driver needs IMDSv2 and no public address."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.artifacts.block_public_acls && aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets
    error_message = "The artifacts bucket must block public access."
  }
  assert {
    condition     = aws_secretsmanager_secret.api_key.recovery_window_in_days == 0
    error_message = "The key secret must go immediately on destroy, so a re-run can recreate it."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.fake.container_definitions)[0].environment[index(jsondecode(aws_ecs_task_definition.fake.container_definitions)[0].environment[*].name, "FAKE_WORKERS")].value == "4"
    error_message = "Two fake server processes per vCPU (2048 CPU units -> 4)."
  }
  assert {
    condition     = startswith(aws_s3_bucket.artifacts.bucket, "llmgw-load-111111111111-eu-west-1")
    error_message = "Bucket name: <prefix>-<account>-<region>."
  }
}

run "rejects_bad_prefix" {
  command = plan
  variables {
    name_prefix = "Load_Test"
  }
  expect_failures = [var.name_prefix]
}

run "rejects_gateway_url_with_path" {
  command = plan
  variables {
    gateway_url = "http://internal-gw.elb.eu-west-1.amazonaws.com/v1"
  }
  expect_failures = [var.gateway_url]
}

run "rejects_inverted_token_range" {
  command = plan
  variables {
    fake_profile = { ttft_ms = 0, itl_ms = 0, tokens_min = 10, tokens_max = 5, jitter = 0, tokens_per_chunk = 1 }
  }
  expect_failures = [var.fake_profile]
}
