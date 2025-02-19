# We replicate the logic:
#  Secret for DB user "llmproxy", random password, exclude punctuation
#  Secret for DB user "middleware", random password, exclude punctuation

# Random passwords
resource "random_password" "db_password_main" {
  length  = 16
  special = false
}

resource "random_password" "db_password_middleware" {
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

resource "aws_secretsmanager_secret" "db_secret_middleware" {
  name_prefix = "${var.name}-DBMiddlewareSecret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_secret_middleware_version" {
  secret_id     = aws_secretsmanager_secret.db_secret_middleware.id
  secret_string = jsonencode({
    username = "middleware"
    password = random_password.db_password_middleware.result
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

# Database #1: litellm
resource "aws_db_instance" "database" {
  identifier                = "${var.name}-litellm-db"
  engine                    = "postgres"
  engine_version           = "15" # or "15.x"
  instance_class            = "db.t3.micro"
  storage_type              = "gp3"
  allocated_storage         = 20
  storage_encrypted         = true
  db_name                      = "litellm"
  db_subnet_group_name      = aws_db_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.db_sg.id]
  username                  = jsondecode(aws_secretsmanager_secret_version.db_secret_main_version.secret_string)["username"]
  password                  = jsondecode(aws_secretsmanager_secret_version.db_secret_main_version.secret_string)["password"]
  skip_final_snapshot       = true
  deletion_protection       = false
}

# Database #2: middleware
resource "aws_db_instance" "database_middleware" {
  identifier                = "${var.name}-middleware-db"
  engine                    = "postgres"
  engine_version            = "15"
  instance_class            = "db.t3.micro"
  storage_type              = "gp3"
  allocated_storage         = 20
  storage_encrypted         = true
  db_name                      = "middleware"
  db_subnet_group_name      = aws_db_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.db_sg.id]
  username                  = jsondecode(aws_secretsmanager_secret_version.db_secret_middleware_version.secret_string)["username"]
  password                  = jsondecode(aws_secretsmanager_secret_version.db_secret_middleware_version.secret_string)["password"]
  skip_final_snapshot       = true
  deletion_protection       = false
}