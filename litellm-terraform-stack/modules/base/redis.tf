#############################################
# REDIS SECURITY GROUP
#############################################

resource "aws_security_group" "redis_sg" {
  name        = "${var.name}-redis-sg"
  description = "Security group for Redis cluster"
  vpc_id      = local.final_vpc_id

  egress {
    description = "allow all outbound access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#############################################
# REDIS SUBNET GROUP
#############################################

resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name        = "litellm-redis-subnet-group"
  description = "Subnet group for Redis cluster"
  subnet_ids  = local.chosen_subnet_ids
}

#############################################
# REDIS PARAMETER GROUP
#############################################

resource "aws_elasticache_parameter_group" "redis_parameter_group" {
  name               = "${var.name}-redis-parameter-group"
  family             = "redis7"
  description        = "Redis parameter group"
  parameter {
    name  = "timeout" 
    value = "0"
  }
  # Add additional parameters if desired.
}

#############################################
# REDIS REPLICATION GROUP
#############################################

# Random passwords
resource "random_password" "redis_password_main" {
  length  = 18
  special = false
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id          = "${var.name}-redis"
  description = "redis"
  engine                        = "redis"
  engine_version                = "7.1"
  node_type = var.redis_node_type
  num_cache_clusters = var.redis_num_cache_clusters
  automatic_failover_enabled    = true
  parameter_group_name = aws_elasticache_parameter_group.redis_parameter_group.name
  subnet_group_name             = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids            = [aws_security_group.redis_sg.id]
  port                          = 6379
  multi_az_enabled = true
  at_rest_encryption_enabled    = true
  transit_encryption_enabled    = true
  transit_encryption_mode      = "required"
  auth_token = random_password.redis_password_main.result
  auth_token_update_strategy = "SET"

  depends_on = [
    aws_elasticache_subnet_group.redis_subnet_group,
    aws_elasticache_parameter_group.redis_parameter_group
  ]
}
