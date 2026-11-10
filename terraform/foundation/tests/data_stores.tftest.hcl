# Data-store protection, logging and key wiring, with mocked
# providers. Default variables plan the created-VPC path.

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

# Generated values are normally unknown until apply; make them known at plan
# time so the wiring assertions can read them.
override_resource {
  target          = aws_s3_bucket.config
  override_during = plan
  values          = { arn = "arn:aws:s3:::llmgw-config-mock", bucket = "llmgw-config-mock" }
}

override_resource {
  target          = aws_secretsmanager_secret.master_key
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-master-key-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.salt_key
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-salt-key-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.redis_auth
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-redis-auth-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.ui_password
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-ui-password-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.database_url
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-database-url-abc" }
}

run "rds_is_hardened_by_default" {
  command = plan

  assert {
    condition     = aws_db_instance.database.multi_az && aws_db_instance.database.storage_encrypted
    error_message = "The database must be Multi-AZ and encrypted."
  }

  assert {
    condition     = aws_db_instance.database.deletion_protection && !aws_db_instance.database.skip_final_snapshot && startswith(aws_db_instance.database.final_snapshot_identifier, "llmgw-litellm-db-final-") && !aws_db_instance.database.delete_automated_backups
    error_message = "Deletion protection, a random-suffixed final snapshot and kept automated backups must be on by default."
  }

  assert {
    condition     = aws_db_instance.database.backup_retention_period == 30 && aws_db_instance.database.copy_tags_to_snapshot
    error_message = "Backups must be kept for 30 days by default."
  }

  assert {
    condition     = aws_db_instance.database.apply_immediately == false
    error_message = "Database changes must wait for the maintenance window."
  }

  assert {
    condition     = aws_db_instance.database.identifier == "llmgw-litellm-db" && aws_db_instance.database.engine == "postgres"
    error_message = "The database identifier must derive from deployment_name."
  }
}

run "db_logs_schema_changes_and_slow_queries_only" {
  command = plan

  assert {
    condition = anytrue([
      for p in aws_db_parameter_group.postgres.parameter : p.name == "log_statement" && p.value == "ddl"
    ])
    error_message = "log_statement must be ddl: logging every statement would send spend logs, keys and team data to CloudWatch."
  }

  assert {
    condition = anytrue([
      for p in aws_db_parameter_group.postgres.parameter : p.name == "log_min_duration_statement" && p.value == "5000"
    ])
    error_message = "Only slow queries (>= 5 s) may be logged."
  }

  assert {
    condition     = contains(aws_db_instance.database.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "The postgresql log export must be enabled."
  }
}

run "redis_is_tls_multi_az_with_auth" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.redis.transit_encryption_enabled && aws_elasticache_replication_group.redis.transit_encryption_mode == "required"
    error_message = "Redis must require TLS in transit."
  }

  assert {
    condition     = aws_elasticache_replication_group.redis.multi_az_enabled && aws_elasticache_replication_group.redis.automatic_failover_enabled && aws_elasticache_replication_group.redis.num_cache_clusters == 2
    error_message = "Redis must be Multi-AZ with automatic failover."
  }

  # The provider types this attribute as a string.
  assert {
    condition     = tobool(aws_elasticache_replication_group.redis.at_rest_encryption_enabled)
    error_message = "Redis must be encrypted at rest."
  }

  # The token is write-only: set through auth_token_wo (never stored), in the
  # same run as its secret.
  assert {
    condition     = aws_elasticache_replication_group.redis.auth_token == null && aws_elasticache_replication_group.redis.auth_token_wo_version == 1
    error_message = "Redis must require an auth token, set write-only (auth_token_wo) so it never reaches state."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.redis_auth.secret_string == null && aws_secretsmanager_secret_version.redis_auth.secret_string_wo_version == aws_elasticache_replication_group.redis.auth_token_wo_version
    error_message = "The Redis auth token secret must be written write-only with the same version as the replication group's token."
  }
}

run "config_bucket_is_versioned_and_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.config.versioning_configuration[0].status == "Enabled"
    error_message = "The config bucket must be versioned so a bad config can be rolled back."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.config.block_public_acls && aws_s3_bucket_public_access_block.config.block_public_policy && aws_s3_bucket_public_access_block.config.ignore_public_acls && aws_s3_bucket_public_access_block.config.restrict_public_buckets
    error_message = "All four public-access blocks must be on."
  }

  assert {
    condition     = aws_s3_bucket.config.force_destroy == false
    error_message = "The config bucket must be kept on destroy while deletion protection is on."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.config.policy, "aws:SecureTransport")
    error_message = "The bucket policy must deny non-TLS access."
  }
}

run "secrets_have_recovery_windows_and_stay_out_of_outputs" {
  command = plan

  assert {
    condition = alltrue([
      aws_secretsmanager_secret.master_key.recovery_window_in_days == 7,
      aws_secretsmanager_secret.salt_key.recovery_window_in_days == 7,
      aws_secretsmanager_secret.redis_auth.recovery_window_in_days == 7,
      aws_secretsmanager_secret.ui_password.recovery_window_in_days == 7,
      aws_secretsmanager_secret.database_url.recovery_window_in_days == 7,
    ])
    error_message = "Every generated secret must keep a 7-day recovery window by default."
  }

  assert {
    condition     = output.master_key_secret_arn == aws_secretsmanager_secret.master_key.arn && output.salt_key_secret_arn == aws_secretsmanager_secret.salt_key.arn
    error_message = "Outputs must expose the master/salt key secret ARNs (never values)."
  }

  assert {
    condition     = output.redis_auth_secret_arn == aws_secretsmanager_secret.redis_auth.arn && output.database_url_secret_arn == aws_secretsmanager_secret.database_url.arn && output.ui_password_secret_arn == aws_secretsmanager_secret.ui_password.arn
    error_message = "Outputs must expose the Redis auth, DATABASE_URL and UI password secret ARNs (never values)."
  }
}

run "customer_kms_key_covers_db_redis_secrets_logs_s3" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_db_instance.database.kms_key_id == var.kms_key_arn && aws_db_instance.database.performance_insights_kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt the database and Performance Insights."
  }

  assert {
    condition     = aws_elasticache_replication_group.redis.kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt Redis at rest."
  }

  assert {
    condition = alltrue([
      aws_secretsmanager_secret.master_key.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.salt_key.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.redis_auth.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.ui_password.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.database_url.kms_key_id == var.kms_key_arn,
    ])
    error_message = "The customer key must encrypt every secret."
  }

  assert {
    condition     = aws_cloudwatch_log_group.vpc_flow_logs[0].kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt the flow log group."
  }

  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql.kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt the PostgreSQL log group."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.config.rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" && r.apply_server_side_encryption_by_default[0].kms_master_key_id == var.kms_key_arn
    ])
    error_message = "The customer key must encrypt the config bucket."
  }

  assert {
    condition     = output.kms_key_arn == var.kms_key_arn
    error_message = "The kms_key_arn output must pass the key through."
  }
}

run "aws_managed_keys_when_no_customer_key" {
  command = plan

  # The database's kms_key_id is computed at apply (RDS picks its default
  # aws/rds key), so only Redis is assertable at plan time.
  assert {
    condition     = aws_elasticache_replication_group.redis.kms_key_id == null
    error_message = "Null kms_key_arn must fall back to AWS-managed keys."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.config.rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    ])
    error_message = "Null kms_key_arn must use SSE-S3 on the bucket."
  }
}

run "protection_off_allows_teardown" {
  command = plan

  variables {
    deletion_protection = false
  }

  assert {
    condition     = !aws_db_instance.database.deletion_protection
    error_message = "deletion_protection = false must release the database."
  }

  assert {
    condition     = !aws_db_instance.database.skip_final_snapshot && aws_db_instance.database.final_snapshot_identifier != null && !aws_db_instance.database.delete_automated_backups
    error_message = "Releasing the database must still take a final snapshot and keep the automated backups."
  }

  assert {
    condition     = aws_s3_bucket.config.force_destroy
    error_message = "deletion_protection = false must let the config bucket be destroyed."
  }
}

run "created_vpc_has_flow_logs_endpoints_and_two_az_subnets" {
  command = plan

  assert {
    condition     = length(aws_vpc.new) == 1 && length(aws_subnet.private) == 2 && length(aws_subnet.public) == 2
    error_message = "The created VPC must have two private and two public subnets."
  }

  assert {
    condition     = aws_subnet.private[0].availability_zone != aws_subnet.private[1].availability_zone
    error_message = "The created private subnets must span two Availability Zones."
  }

  assert {
    condition     = length(aws_flow_log.this) == 1 && aws_cloudwatch_log_group.vpc_flow_logs[0].retention_in_days == 3653
    error_message = "The created VPC must have flow logs with the ten-year (3653-day) default retention."
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3_gateway) == 1 && length(aws_vpc_endpoint.interface) == 0 && length(aws_security_group.vpc_endpoints) == 0
    error_message = "With internet egress the created VPC gets the free S3 gateway endpoint only; interface endpoints are opt-in."
  }

  assert {
    condition     = aws_vpc.new[0].enable_dns_support && aws_vpc.new[0].enable_dns_hostnames
    error_message = "The created VPC must have DNS support and hostnames on (private DNS on the endpoints)."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_internet_gateway.this) == 1
    error_message = "The default created VPC must have egress through a NAT gateway."
  }
}

run "no_internet_mode_has_no_igw_nat_or_public_subnets" {
  command = plan

  variables {
    disable_outbound_network_access = true
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_nat_gateway.this) == 0 && length(aws_subnet.public) == 0
    error_message = "No-internet mode must create no internet gateway, NAT or public subnets."
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 6 && length(aws_vpc_endpoint.s3_gateway) == 1
    error_message = "No-internet mode depends on the VPC endpoints: the S3 gateway and the 6 interface endpoints."
  }

  assert {
    condition     = sort(keys(aws_vpc_endpoint.interface)) == sort(["secretsmanager", "ecr_api", "ecr_dkr", "logs", "sts", "bedrock_runtime"]) && !contains(keys(aws_vpc_endpoint.interface), "bedrock")
    error_message = "The interface endpoints are the data-plane set; the Bedrock control-plane endpoint is not created."
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "No-internet mode still needs the two private subnets."
  }
}

run "resource_names_derive_from_deployment_name" {
  command = plan

  variables {
    deployment_name = "second"
  }

  assert {
    condition = alltrue([
      aws_db_instance.database.identifier == "second-litellm-db",
      aws_elasticache_replication_group.redis.replication_group_id == "second-redis",
      aws_security_group.data_ingress.name == "second-data-client-sg",
      aws_security_group.db.name == "second-db-sg",
      aws_security_group.redis.name == "second-redis-sg",
      aws_db_subnet_group.main.name == "second-db-subnet-group",
      aws_elasticache_subnet_group.redis.name == "second-redis-subnet-group",
    ])
    error_message = "Every resource name must derive from deployment_name so two deployments in one account do not collide."
  }
}

# Every generated value is ephemeral and written write-only: nothing secret is
# in the plan or state, only the *_wo_version numbers.
run "generated_secrets_never_reach_state" {
  command = plan

  assert {
    condition = alltrue([
      for v in [
        aws_secretsmanager_secret_version.master_key,
        aws_secretsmanager_secret_version.salt_key,
        aws_secretsmanager_secret_version.redis_auth,
        aws_secretsmanager_secret_version.ui_password,
        aws_secretsmanager_secret_version.database_url,
      ] : v.secret_string == null && v.secret_binary == null && v.secret_string_wo_version == 1
    ])
    error_message = "Every generated secret must be written through secret_string_wo (version 1), with no value in state."
  }

  assert {
    condition     = aws_db_instance.database.password == null && aws_db_instance.database.password_wo_version == 1 && aws_db_instance.database.manage_master_user_password != true
    error_message = "The database password must be set write-only (password_wo) and never stored."
  }
}

run "monitoring_identifiers_exported" {
  command = plan

  assert {
    condition     = output.rds_instance_identifier == "llmgw-litellm-db" && output.rds_instance_identifier == aws_db_instance.database.identifier
    error_message = "rds_instance_identifier must be the RDS instance identifier (app alarms use it as DBInstanceIdentifier)."
  }

  assert {
    condition     = output.redis_replication_group_id == "llmgw-redis" && output.redis_num_cache_clusters == 2 && aws_elasticache_replication_group.redis.num_cache_clusters == 2 && aws_elasticache_replication_group.redis.node_type == "cache.t3.micro"
    error_message = "The Redis replication group ID and node count must be exported for the app's per-node alarms."
  }
}

run "interface_endpoints_on_request_with_egress" {
  command = plan

  variables {
    create_interface_endpoints = true
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 6 && length(aws_security_group.vpc_endpoints) == 1 && length(aws_nat_gateway.this) == 1
    error_message = "create_interface_endpoints must add the 6 interface endpoints next to the NAT egress."
  }
}

run "rds_storage_autoscaling_by_default" {
  command = plan

  assert {
    condition     = aws_db_instance.database.allocated_storage == 20 && aws_db_instance.database.max_allocated_storage == 200
    error_message = "RDS must start at 20 GB and autoscale storage up to 200 GB by default."
  }
}

run "rds_default_instance_class_is_the_baseline" {
  command = plan

  assert {
    condition     = aws_db_instance.database.instance_class == "db.t4g.large"
    error_message = "db.t4g.large is the supported baseline instance class."
  }
}

run "throwaway_destroy_skips_snapshot_only_when_explicit" {
  command = plan

  variables {
    deletion_protection           = false
    destroy_data_without_snapshot = true
  }

  assert {
    condition     = aws_db_instance.database.skip_final_snapshot && aws_db_instance.database.final_snapshot_identifier == null && aws_db_instance.database.delete_automated_backups
    error_message = "Only destroy_data_without_snapshot may skip the final snapshot and delete the automated backups."
  }
}

run "postgresql_log_group_is_managed_before_the_database" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql.name == "/aws/rds/instance/${aws_db_instance.database.identifier}/postgresql"
    error_message = "The managed log group must be the one RDS exports the PostgreSQL log to."
  }

  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql.retention_in_days == 3653
    error_message = "The PostgreSQL log group must keep the shared ten-year retention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.rds_postgresql.skip_destroy
    error_message = "With deletion_protection on (the default), destroy must keep the PostgreSQL log group."
  }
}

run "postgresql_log_group_is_destroyable_when_protection_is_off" {
  command = plan

  variables {
    deletion_protection = false
  }

  assert {
    condition     = !aws_cloudwatch_log_group.rds_postgresql.skip_destroy
    error_message = "deletion_protection = false must let destroy remove the PostgreSQL log group."
  }
}

run "db_logs_never_carry_bind_parameters" {
  command = plan

  assert {
    condition = alltrue([
      for n in ["log_parameter_max_length", "log_parameter_max_length_on_error"] :
      anytrue([for p in aws_db_parameter_group.postgres.parameter : p.name == n && p.value == "0"])
    ])
    error_message = "Logged statements must not include bind-parameter values."
  }
}

run "config_bucket_expires_only_noncurrent_versions" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_lifecycle_configuration.config.rule[0].noncurrent_version_expiration[0].noncurrent_days == 90 &&
      length(aws_s3_bucket_lifecycle_configuration.config.rule[0].expiration) == 0
    )
    error_message = "The config bucket may expire noncurrent versions only; expiring current objects would delete a live config."
  }
}
