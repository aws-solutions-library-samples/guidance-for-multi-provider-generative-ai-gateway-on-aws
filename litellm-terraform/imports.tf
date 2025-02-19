# Lookup the existing VPC
data "aws_vpc" "this" {
  id = var.vpcId
}

# Lookup existing security groups
data "aws_security_group" "redis" {
  id = var.redisSecurityGroupId
}

data "aws_security_group" "db" {
  id = var.rdsSecurityGroupId
}

# Lookup existing RDS secrets from Secrets Manager
data "aws_secretsmanager_secret" "litellm_db_secret" {
  arn = var.rdsLitellmSecretArn
}

data "aws_secretsmanager_secret" "middleware_db_secret" {
  arn = var.rdsMiddlewareSecretArn
}

# Retrieve the actual secret value for the database passwords
# (only if needed for building a DB connection URL in Terraform)
data "aws_secretsmanager_secret_version" "litellm_db_secret_ver" {
  secret_id = data.aws_secretsmanager_secret.litellm_db_secret.id
}

data "aws_secretsmanager_secret_version" "middleware_db_secret_ver" {
  secret_id = data.aws_secretsmanager_secret.middleware_db_secret.id
}

# If publicLoadBalancer = true, we fetch the existing public hosted zone
data "aws_route53_zone" "public_zone" {
  count       = var.publicLoadBalancer ? 1 : 0
  name        = var.hostedZoneName
  private_zone = false
}

# If publicLoadBalancer = false, we create a private hosted zone
resource "aws_route53_zone" "private_zone" {
  count = var.publicLoadBalancer ? 0 : 1

  name = var.hostedZoneName
  vpc {
    vpc_id = data.aws_vpc.this.id
  }
}

# ECR Repositories
data "aws_ecr_repository" "litellm" {
  name = var.ecrLitellmRepository
}

data "aws_ecr_repository" "middleware" {
  name = var.ecrMiddlewareRepository
}