# Data-store access model: membership of the data-ingress security group is
# what grants access to RDS and Redis. The app attaches it to the gateway
# tasks; any other client (for example pods on an EKS cluster) is admitted
# through the extra_data_ingress_* inputs. The data stores accept nothing else.

locals {
  db_port    = 5432
  redis_port = 6379

  extra_ingress_sgs = toset(var.extra_data_ingress_security_group_ids)
  # CIDR strings are not valid resource-address keys as-is; index by position.
  extra_ingress_cidrs = { for i, cidr in var.extra_data_ingress_cidrs : i => cidr }
}

resource "aws_security_group" "data_ingress" {
  name        = "${var.deployment_name}-data-client-sg"
  description = "Membership grants access to RDS and Redis; attach to any gateway client of the data stores"
  vpc_id      = local.vpc_id

  tags = { Name = "${var.deployment_name}-data-client-sg" }
}

resource "aws_vpc_security_group_egress_rule" "data_ingress_to_db" {
  security_group_id            = aws_security_group.data_ingress.id
  description                  = "PostgreSQL to the gateway database"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = local.db_port
  to_port                      = local.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "data_ingress_to_redis" {
  security_group_id            = aws_security_group.data_ingress.id
  description                  = "TLS Redis to the gateway cache"
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "db" {
  name        = "${var.deployment_name}-db-sg"
  description = "RDS PostgreSQL: PostgreSQL from the data-ingress security group and the extra ingress inputs only"
  vpc_id      = local.vpc_id

  tags = { Name = "${var.deployment_name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_data_ingress" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the data-ingress security group"
  referenced_security_group_id = aws_security_group.data_ingress.id
  from_port                    = local.db_port
  to_port                      = local.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_extra_sg" {
  for_each                     = local.extra_ingress_sgs
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from extra_data_ingress_security_group_ids"
  referenced_security_group_id = each.value
  from_port                    = local.db_port
  to_port                      = local.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_extra_cidr" {
  for_each          = local.extra_ingress_cidrs
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from extra_data_ingress_cidrs"
  cidr_ipv4         = each.value
  from_port         = local.db_port
  to_port           = local.db_port
  ip_protocol       = "tcp"
}

resource "aws_security_group" "redis" {
  name        = "${var.deployment_name}-redis-sg"
  description = "ElastiCache Redis: TLS Redis from the data-ingress security group and the extra ingress inputs only"
  vpc_id      = local.vpc_id

  tags = { Name = "${var.deployment_name}-redis-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_data_ingress" {
  security_group_id            = aws_security_group.redis.id
  description                  = "TLS Redis from the data-ingress security group"
  referenced_security_group_id = aws_security_group.data_ingress.id
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_extra_sg" {
  for_each                     = local.extra_ingress_sgs
  security_group_id            = aws_security_group.redis.id
  description                  = "TLS Redis from extra_data_ingress_security_group_ids"
  referenced_security_group_id = each.value
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_extra_cidr" {
  for_each          = local.extra_ingress_cidrs
  security_group_id = aws_security_group.redis.id
  description       = "TLS Redis from extra_data_ingress_cidrs"
  cidr_ipv4         = each.value
  from_port         = local.redis_port
  to_port           = local.redis_port
  ip_protocol       = "tcp"
}
