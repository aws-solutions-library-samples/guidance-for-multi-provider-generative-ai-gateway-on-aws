# Generated secrets written once and salt-key protection, applied against a mocked
# AWS provider (no credentials, no AWS) with the real, local random provider
# (mock providers do not support ephemeral resources). Only the secrets are
# applied, so unrelated resources need no realistic mock values.

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

provider "random" {}

variables {
  deployment_name = "llmgw"
}

run "secrets_created_at_version_1" {
  command = apply

  plan_options {
    target = [
      aws_secretsmanager_secret_version.master_key,
      aws_secretsmanager_secret_version.salt_key,
      aws_secretsmanager_secret_version.ui_password,
    ]
  }

  assert {
    condition     = aws_secretsmanager_secret_version.master_key.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.salt_key.secret_string_wo_version == 1
    error_message = "Generated secrets are created at version 1."
  }
}

# A second apply generates new ephemeral values; none is re-sent, so the salt
# key keeps its first value.
run "reapply_never_rewrites_the_salt_key" {
  command = apply

  plan_options {
    target = [
      aws_secretsmanager_secret_version.master_key,
      aws_secretsmanager_secret_version.salt_key,
      aws_secretsmanager_secret_version.ui_password,
    ]
  }

  assert {
    condition     = aws_secretsmanager_secret_version.salt_key.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.salt_key.secret_string == null
    error_message = "The salt key must never be re-sent: a new value makes every stored provider credential unreadable."
  }
}
