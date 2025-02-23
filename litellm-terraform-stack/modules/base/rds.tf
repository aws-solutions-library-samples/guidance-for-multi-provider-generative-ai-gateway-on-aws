# We replicate the logic:
#  Secret for DB user "llmproxy", random password, exclude punctuation

# Random passwords
resource "random_password" "db_password_main" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "db_secret_main" {
  name_prefix = "${var.name}-DBSecret-"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_secret_main_version" {
  secret_id     = aws_secretsmanager_secret.db_secret_main.id
  secret_string = jsonencode({
    username = "llmproxy"
    password = random_password.db_password_main.result
  })
}

#############################################
# RDS SECURITY GROUP
#############################################

resource "aws_security_group" "db_sg" {
  name        = "${var.name}-db-sg"
  description = "Security group for RDS instance"
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
# RDS INSTANCES
#############################################

# Subnet group for the DB
resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-db-subnet-group"
  subnet_ids = local.chosen_subnet_ids
}

resource "aws_db_parameter_group" "example_pg" {
  name   = "rds-postgres-parameter-group"
  # Update the family to match your PostgreSQL version
  family = "postgres15"

  # Enable logging of all statements
  parameter {
    name  = "log_statement"
    value = "all"
  }

  # Log statements that take longer than 1ms
  parameter {
    name  = "log_min_duration_statement"
    value = "1"
  }
}

# Database #1: litellm
resource "aws_db_instance" "database" {
  identifier                = "${var.name}-litellm-db"
  engine                    = "postgres"
  engine_version           = "15" # or "15.x"
  instance_class            = var.rds_instance_class
  storage_type              = "gp3"
  allocated_storage         = var.rds_allocated_storage
  storage_encrypted         = true
  db_name                      = "litellm"
  db_subnet_group_name      = aws_db_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.db_sg.id]
  username                  = jsondecode(aws_secretsmanager_secret_version.db_secret_main_version.secret_string)["username"]
  password                  = jsondecode(aws_secretsmanager_secret_version.db_secret_main_version.secret_string)["password"]
  skip_final_snapshot       = true
  deletion_protection       = false
  multi_az = true
  performance_insights_enabled = true
  enabled_cloudwatch_logs_exports = ["general", "error", "slowquery", "postgresql"]
  auto_minor_version_upgrade = true
  monitoring_interval = 60
  parameter_group_name = aws_db_parameter_group.example_pg.name
  copy_tags_to_snapshot     = true
}