# The consumer surface of the foundation:
# everything a non-ECS consumer of the foundation needs. `app` consumes these
# through plain input variables only — deploy/deploy.sh wires
# `terraform output -json` from this root module into terraform/app. Keep names
# in sync with app's variables. Secret ARNs only — never secret values.

output "vpc_id" {
  description = "The VPC everything runs in (created or brought)."
  value       = local.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets for the gateway tasks and data stores."
  value       = local.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets for an internet-facing entry point (empty in private no-internet or BYO-private deployments)."
  value       = local.public_subnet_ids
}

output "vpc_cidr" {
  description = "The VPC's IPv4 CIDR."
  value       = local.vpc_cidr
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)."
  value       = aws_db_instance.database.endpoint
}

output "database_url_secret_arn" {
  description = "Secrets Manager ARN of the full DATABASE_URL (the value never appears in state outputs or variables)."
  value       = aws_secretsmanager_secret.database_url.arn
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_port" {
  description = "ElastiCache Redis port."
  value       = local.redis_port
}

output "redis_auth_secret_arn" {
  description = "Secrets Manager ARN of the Redis auth token."
  value       = aws_secretsmanager_secret.redis_auth.arn
}

output "config_bucket_name" {
  description = "Versioned S3 bucket holding the rendered LiteLLM config."
  value       = aws_s3_bucket.config.bucket
}

output "master_key_secret_arn" {
  description = "Secrets Manager ARN of the generated LiteLLM master key."
  value       = aws_secretsmanager_secret.master_key.arn
}

output "salt_key_secret_arn" {
  description = "Secrets Manager ARN of the generated LiteLLM salt key (never rotate it)."
  value       = aws_secretsmanager_secret.salt_key.arn
}

output "ui_password_secret_arn" {
  description = "Secrets Manager ARN of the LiteLLM admin UI password (separate from the master key)."
  value       = aws_secretsmanager_secret.ui_password.arn
}

output "kms_key_arn" {
  description = "The customer KMS key, or null when AWS-managed keys are used."
  value       = var.kms_key_arn
}

output "data_ingress_security_group_id" {
  description = "The security group whose membership grants access to RDS and Redis; app attaches it to the gateway tasks."
  value       = aws_security_group.data_ingress.id
}

# Identifiers for monitoring (app's observability alarms and dashboard).

output "rds_instance_identifier" {
  description = "RDS instance identifier (CloudWatch DBInstanceIdentifier dimension)."
  value       = aws_db_instance.database.identifier
}

output "redis_replication_group_id" {
  description = "ElastiCache replication group ID; member clusters are <id>-001, <id>-002, ..."
  value       = aws_elasticache_replication_group.redis.replication_group_id
}

output "redis_num_cache_clusters" {
  description = "Number of Redis cache clusters (nodes) in the replication group."
  value       = local.redis_num_cache_clusters
}

output "vpn_security_group_id" {
  description = "Security group of the demo Client VPN, to admit on the gateway entry point; null when create_vpn is false."
  value       = var.create_vpn ? module.vpn[0].security_group_id : null
}
