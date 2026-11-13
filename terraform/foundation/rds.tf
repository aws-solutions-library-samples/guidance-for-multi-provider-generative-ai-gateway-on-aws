# RDS PostgreSQL: Multi-AZ, encrypted, deletion-protected by default, with a
# final snapshot on every destroy (automated backups kept), 30-day backups and
# changes applied in the maintenance window.
# The database logs schema changes and slow queries only — never every
# statement, which would send LiteLLM's spend logs, keys and team data to
# CloudWatch.

locals {
  db_username = "llmproxy"
  db_name     = "litellm"

  # The supported baseline. A major version lets RDS pick the latest minor
  # release; the parameter-group family follows it.
  db_engine_version = "17"
  db_major_version  = split(".", local.db_engine_version)[0]
  # Graviton, 2 vCPU / 8 GiB: room for shared_buffers next to LiteLLM's
  # ever-growing spend-log table, and ~880 connections by the PostgreSQL
  # default formula, enough for 20 tasks during a rolling deploy.
  db_instance_class = "db.t4g.large"
  # gp3 gives its 3000 IOPS baseline below 400 GB; storage autoscaling grows
  # the volume up to the ceiling because LiteLLM writes a spend-log row per
  # request and keeps them indefinitely by default.
  db_allocated_storage     = 20
  db_max_allocated_storage = 200
  db_backup_retention_days = 30
}

ephemeral "random_password" "db" {
  length  = 16
  special = false # keeps the DATABASE_URL free of characters that need URL-encoding
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.deployment_name}-db-subnet-group"
  subnet_ids = local.private_subnet_ids
}

resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${var.deployment_name}-postgres${local.db_major_version}-"
  family      = "postgres${local.db_major_version}"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "5000"
  }

  # Slow-query and error log lines would otherwise include bind-parameter
  # values (user emails, key aliases, request metadata).
  parameter {
    name  = "log_parameter_max_length"
    value = "0"
  }

  parameter {
    name  = "log_parameter_max_length_on_error"
    value = "0"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The final snapshot name carries a random suffix so destroy/redeploy cycles
# of the same deployment_name do not collide with an earlier snapshot.
resource "random_id" "final_snapshot" {
  byte_length = 4
}

# The log group RDS exports the PostgreSQL log to. Declared here, ahead of the
# instance, so it carries the shared retention and the customer key; left to
# RDS it would be created on first export with neither.
locals {
  db_identifier = "${var.deployment_name}-litellm-db"
}

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${local.db_identifier}/postgresql"
  retention_in_days = local.log_retention_days
  kms_key_id        = var.kms_key_arn
  skip_destroy      = var.deletion_protection
}

resource "aws_db_instance" "database" {
  identifier     = local.db_identifier
  engine         = "postgres"
  engine_version = local.db_engine_version
  instance_class = local.db_instance_class

  storage_type          = "gp3"
  allocated_storage     = local.db_allocated_storage
  max_allocated_storage = local.db_max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name                = local.db_name
  username               = local.db_username
  password_wo            = ephemeral.random_password.db.result
  password_wo_version    = local.generated_secrets_wo_version
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  multi_az               = true

  # Turning deletion protection off only allows the destroy; the data is still
  # kept in a final snapshot and the automated backups. Only the explicit
  # destroy_data_without_snapshot (throwaway deployments) drops both.
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.destroy_data_without_snapshot
  final_snapshot_identifier = var.destroy_data_without_snapshot ? null : "${var.deployment_name}-litellm-db-final-${random_id.final_snapshot.hex}"
  delete_automated_backups  = var.destroy_data_without_snapshot
  backup_retention_period   = local.db_backup_retention_days
  copy_tags_to_snapshot     = true
  apply_immediately         = false # changes wait for the maintenance window

  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn

  # The PostgreSQL log goes to the group declared above, never to one RDS
  # creates on its own.
  depends_on = [aws_cloudwatch_log_group.rds_postgresql]
}
