# Generated secrets, in Secrets Manager only. Values never reach variables,
# outputs, plan files or state: each one is an ephemeral random value written
# through a write-only argument (secret_string_wo, password_wo, auth_token_wo),
# so Terraform keeps only the *_wo_version number. Deleted secrets keep a
# 7-day recovery window; every secret is named with a unique name_prefix, so a
# destroy and redeploy of the same deployment_name inside that window never
# collides with a secret pending deletion.
#
# Ephemeral values are regenerated on every run, but a write-only argument is
# sent only when its resource is created or its version changes.

locals {
  secret_recovery_window_days = 7

  # Write-only version of every generated value: the values are written once,
  # at creation, and never changed by this stack.
  generated_secrets_wo_version = 1
}

# LiteLLM master key: the break-glass admin credential. The UI gets its own
# password below so the master key is never used for routine sign-in.
ephemeral "random_password" "master_key" {
  length  = 21
  special = false
}

resource "aws_secretsmanager_secret" "master_key" {
  name_prefix             = "${var.deployment_name}-master-key-"
  description             = "LiteLLM master key (sk-...)"
  recovery_window_in_days = local.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

# A plain sk-... string, not JSON: deploy/smoke-test.sh --key-secret-arn and
# LiteLLM read the SecretString verbatim.
resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id                = aws_secretsmanager_secret.master_key.id
  secret_string_wo         = "sk-${ephemeral.random_password.master_key.result}"
  secret_string_wo_version = local.generated_secrets_wo_version
}

# The salt key encrypts provider credentials stored in LiteLLM's database.
# NEVER change it: a new value makes those stored credentials unreadable. Its
# value and version are ignored after creation, so no later edit re-sends a
# new value.
ephemeral "random_password" "salt_key" {
  length  = 21
  special = false
}

resource "aws_secretsmanager_secret" "salt_key" {
  name_prefix             = "${var.deployment_name}-salt-key-"
  description             = "LiteLLM salt key - never rotate it"
  recovery_window_in_days = local.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "salt_key" {
  secret_id                = aws_secretsmanager_secret.salt_key.id
  secret_string_wo         = "sk-${ephemeral.random_password.salt_key.result}"
  secret_string_wo_version = local.generated_secrets_wo_version

  lifecycle {
    ignore_changes = [secret_string_wo, secret_string_wo_version]
  }
}

# Redis auth token: the same ephemeral value goes to ElastiCache (redis.tf) and
# to this secret in one run.
ephemeral "random_password" "redis_auth" {
  length  = 32
  special = false # ElastiCache auth tokens forbid '@', '"' and '/'
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name_prefix             = "${var.deployment_name}-redis-auth-"
  description             = "ElastiCache Redis auth token"
  recovery_window_in_days = local.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id                = aws_secretsmanager_secret.redis_auth.id
  secret_string_wo         = ephemeral.random_password.redis_auth.result
  secret_string_wo_version = local.generated_secrets_wo_version

  # A replaced replication group is created with this run's token; re-write
  # the secret in the same run so the two never diverge.
  lifecycle {
    replace_triggered_by = [aws_elasticache_replication_group.redis.id]
  }
}

# Without UI_PASSWORD, LiteLLM accepts the master key as the admin UI password.
# A separate password keeps the master key break-glass only.
ephemeral "random_password" "ui_password" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "ui_password" {
  name_prefix             = "${var.deployment_name}-ui-password-"
  description             = "LiteLLM admin UI password (separate from the master key)"
  recovery_window_in_days = local.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "ui_password" {
  secret_id                = aws_secretsmanager_secret.ui_password.id
  secret_string_wo         = ephemeral.random_password.ui_password.result
  secret_string_wo_version = local.generated_secrets_wo_version
}

# The full DATABASE_URL, so consumers need one secret, not credentials plus
# endpoint assembly. The password (rds.tf) is generated without special
# characters, so no URL-encoding is needed. sslmode=require makes the client
# refuse an unencrypted connection. The value is write-only and written once
# per *_wo_version, so a URL already stored is not re-written by this.
resource "aws_secretsmanager_secret" "database_url" {
  name_prefix             = "${var.deployment_name}-database-url-"
  description             = "Full postgresql:// DATABASE_URL for LiteLLM"
  recovery_window_in_days = local.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id                = aws_secretsmanager_secret.database_url.id
  secret_string_wo         = "postgresql://${local.db_username}:${ephemeral.random_password.db.result}@${aws_db_instance.database.endpoint}/${local.db_name}?sslmode=require"
  secret_string_wo_version = local.generated_secrets_wo_version

  # A replaced database (new endpoint, created with this run's password) gets
  # its URL re-written in the same run. Only replacement changes the id, so an
  # in-place database update never re-sends a password RDS did not receive.
  lifecycle {
    replace_triggered_by = [aws_db_instance.database.id]
  }
}
