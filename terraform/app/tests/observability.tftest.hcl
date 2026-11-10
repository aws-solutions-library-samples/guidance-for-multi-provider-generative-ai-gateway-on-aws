# The observability module wired into the app, applied against
# mocked providers: ALB/ECS/log-group names from the app, data-store identifiers
# from foundation outputs, and the customer KMS key.
# Nothing touches AWS.

# The generated mock values must pass the provider's client-side ARN validation
# where resources reference each other's ARNs.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock-role"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:loadbalancer/app/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:targetgroup/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:listener/app/mock/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:eu-west-1:111111111111:regional/webacl/mock/00000000-0000-0000-0000-000000000000"
    }
  }

  # The observability module's policy documents and the ARNs its topic and key
  # policy reference must look real to the provider's client-side validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-west-1:111111111111:llmgw-alarms"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  deployment_name = "llmgw"
  certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"

  # Foundation outputs (wired by deploy.sh in real runs).
  vpc_id                         = "vpc-0123456789abcdef0"
  private_subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  vpc_cidr                       = "10.0.0.0/16"
  database_url_secret_arn        = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/database-url-AbCdEf"
  redis_endpoint                 = "llmgw-redis.cache.amazonaws.com"
  redis_port                     = 6379
  redis_auth_secret_arn          = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/redis-auth-AbCdEf"
  config_bucket_name             = "llmgw-config-111111111111-eu-west-1"
  master_key_secret_arn          = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/master-key-AbCdEf"
  salt_key_secret_arn            = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/salt-key-AbCdEf"
  data_ingress_security_group_id = "sg-0123456789abcdef0"
  ui_password_secret_arn         = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/ui-password-AbCdEf"
  rds_instance_identifier        = "llmgw-litellm-db"
  redis_replication_group_id     = "llmgw-redis"
}

# The config upload and the migration gate (module.rollout) call the AWS CLI
# from local-exec provisioners, which run even for an overridden resource.
# Replacing the whole module keeps every test apply away from AWS.
override_module {
  target = module.rollout
}

run "observability_wired_with_defaults" {
  command = apply

  assert {
    condition     = length(module.observability.alarm_names) == 17
    error_message = "The full alarm set (17 at defaults: 2 Redis nodes, log metrics on) must be created with the app."
  }

  assert {
    condition = alltrue([for n in ["llmgw-alb-target-5xx-rate", "llmgw-ecs-running-below-desired", "llmgw-rds-cpu-high", "llmgw-redis-replication-lag", "llmgw-log-errors"] :
    contains(module.observability.alarm_names, n)])
    error_message = "ALB, ECS, RDS, Redis and log-metric alarms must all be present, named from deployment_name."
  }

  assert {
    condition     = module.observability.redis_cache_cluster_ids == tolist(["llmgw-redis-001", "llmgw-redis-002"])
    error_message = "Redis member clusters must derive from the foundation's replication group ID and node count."
  }

  assert {
    condition     = output.dashboard_name == "llmgw-gateway" && output.alarm_topic_arn == "arn:aws:sns:eu-west-1:111111111111:llmgw-alarms"
    error_message = "The dashboard and the module-created alarm topic must be exported by the app."
  }

  assert {
    condition     = module.observability.kms_key_arn != null
    error_message = "Without a customer key, the module must create its own key for the alarm topic."
  }

  # The running-below-desired alarm reads Container Insights metrics.
  assert {
    condition     = [for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"][0] == "enabled"
    error_message = "Container Insights must be on for the ecs-running-below-desired alarm."
  }
}

run "observability_follows_foundation_node_count" {
  command = apply

  variables {
    redis_num_cache_clusters = 3
  }

  assert {
    condition     = module.observability.redis_cache_cluster_ids == tolist(["llmgw-redis-001", "llmgw-redis-002", "llmgw-redis-003"])
    error_message = "The per-node Redis alarms must follow the foundation's redis_num_cache_clusters."
  }
}

run "observability_uses_the_customer_kms_key" {
  command = apply

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111111111111:key/11111111-1111-1111-1111-111111111111"
  }

  assert {
    condition     = module.observability.kms_key_arn == null
    error_message = "With the foundation's customer key, the alarm topic must use it instead of creating another key."
  }
}
