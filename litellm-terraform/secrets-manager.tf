###############################################################################
# Secrets Manager: LiteLLM master/salt keys
###############################################################################
# Generate random strings for master and salt
resource "random_password" "litellm_master" {
  length  = 24
  special = false
}

resource "random_password" "litellm_salt" {
  length  = 24
  special = false
}

# Create a secret (the "shell" or "container" for the key)
resource "aws_secretsmanager_secret" "litellm_master_salt" {
  name_prefix = "LiteLLMMasterSalt-"
}

# Store the generated values
resource "aws_secretsmanager_secret_version" "litellm_master_salt_ver" {
  secret_id = aws_secretsmanager_secret.litellm_master_salt.id

  secret_string = jsonencode({
    LITELLM_MASTER_KEY = random_password.litellm_master.result
    LITELLM_SALT_KEY   = random_password.litellm_salt.result
  })
}

###############################################################################
# Construct DB URLs from existing Secrets Manager password
###############################################################################
# For demonstration, parse the JSON from data sources (the RDS secrets).
# Adjust keys if your secrets structure differ.

locals {
  litellm_db_password     = jsondecode(data.aws_secretsmanager_secret_version.litellm_db_secret_ver.secret_string).password
  middleware_db_password  = jsondecode(data.aws_secretsmanager_secret_version.middleware_db_secret_ver.secret_string).password
}

resource "aws_secretsmanager_secret" "db_url_secret" {
  name_prefix = "DBUrlSecret-"
}

resource "aws_secretsmanager_secret_version" "db_url_secret_ver" {
  secret_id = aws_secretsmanager_secret.db_url_secret.id

  secret_string = "postgresql://llmproxy:${local.litellm_db_password}@${var.rdsLitellmHostname}/litellm"
}

resource "aws_secretsmanager_secret" "db_middleware_url_secret" {
  name_prefix = "DBMiddlewareUrlSecret-"
}

resource "aws_secretsmanager_secret_version" "db_middleware_url_secret_ver" {
  secret_id = aws_secretsmanager_secret.db_middleware_url_secret.id

  secret_string = "postgresql://middleware:${local.middleware_db_password}@${var.rdsMiddlewareHostname}/middleware"
}