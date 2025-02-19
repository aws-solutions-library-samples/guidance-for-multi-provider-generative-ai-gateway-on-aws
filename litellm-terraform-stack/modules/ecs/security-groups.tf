###############################################################################
# (7) Security Groups & Ingress for Redis and RDS
###############################################################################
# Security group for ECS Service tasks
resource "aws_security_group" "ecs_service_sg" {
  name        = "${var.name}-service-sg"
  description = "Security group for ECS Fargate service"
  vpc_id      = var.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"  # "-1" represents all protocols
    cidr_blocks      = ["0.0.0.0/0"]
    description      = "Allow all outbound traffic by default"
  }
}

resource "aws_security_group_rule" "alb_ingress_4000" {
  type                     = "ingress"
  from_port                = 4000
  to_port                  = 4000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_service_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
  description              = "Allow Load Balancer to ECS"
}

resource "aws_security_group_rule" "alb_ingress_3000" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_service_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
  description              = "Allow Load Balancer to ECS"
}


# Allow ECS tasks to connect to Redis
resource "aws_security_group_rule" "redis_ingress" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = var.redis_security_group_id
  source_security_group_id = aws_security_group.ecs_service_sg.id
  description              = "Allow ECS tasks to connect to Redis"
}

# Allow ECS tasks to connect to RDS
resource "aws_security_group_rule" "db_ingress" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.db_security_group_id
  source_security_group_id = aws_security_group.ecs_service_sg.id
  description              = "Allow ECS tasks to connect to RDS"
}

resource "aws_security_group" "alb_sg" {
  name        = "${var.name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = var.vpc_id

  # Allow inbound HTTPS from anywhere (adjust as necessary)
  ingress {
    description = "Allow HTTPS in"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound
  egress {
    description = "Allow all outbound"
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
