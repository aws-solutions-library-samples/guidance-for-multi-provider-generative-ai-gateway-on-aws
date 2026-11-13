# ElastiCache Redis for LiteLLM's router: Multi-AZ with automatic failover,
# TLS required in transit, encrypted at rest, auth token required.

locals {
  # A primary and one replica in a second AZ: the minimum for Multi-AZ with
  # automatic failover. The router keeps only small rate-limit and cooldown
  # state here (plus the response cache).
  redis_node_type          = "cache.t3.micro"
  redis_num_cache_clusters = 2
}

resource "aws_elasticache_subnet_group" "redis" {
  name        = "${var.deployment_name}-redis-subnet-group"
  description = "Subnet group for the gateway Redis cluster"
  subnet_ids  = local.private_subnet_ids
}

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${var.deployment_name}-redis-params"
  family      = "redis7"
  description = "Gateway Redis parameter group"

  # No idle connection timeout: LiteLLM keeps long-lived pooled connections.
  parameter {
    name  = "timeout"
    value = "0"
  }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.deployment_name}-redis"
  description          = "Gateway Redis for the LiteLLM router"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = local.redis_node_type
  port           = local.redis_port

  num_cache_clusters         = local.redis_num_cache_clusters
  multi_az_enabled           = true
  automatic_failover_enabled = true

  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token_wo              = ephemeral.random_password.redis_auth.result
  auth_token_wo_version      = local.generated_secrets_wo_version
  auth_token_update_strategy = "SET"
}
