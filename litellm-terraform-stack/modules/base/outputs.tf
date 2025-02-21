#############################################
# OUTPUTS
#############################################
output "RdsLitellmHostname" {
  description = "The hostname of the LiteLLM RDS instance"
  value       = aws_db_instance.database.endpoint
}

output "RdsLitellmSecretArn" {
  description = "The ARN of the LiteLLM RDS secret"
  value       = aws_secretsmanager_secret.db_secret_main.arn
}

output "RedisHostName" {
  description = "The hostname of the Redis cluster"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "RedisPort" {
  description = "The port of the Redis cluster"
  value       = 6379
}

output "RdsSecurityGroupId" {
  description = "The ID of the RDS security group"
  value       = aws_security_group.db_sg.id
}

output "RedisSecurityGroupId" {
  description = "The ID of the Redis security group"
  value       = aws_security_group.redis_sg.id
}

output "VpcId" {
  description = "The ID of the VPC"
  value       = local.final_vpc_id
}

# If we created the pull-through cache:
output "EksAlbControllerPrivateEcrRepositoryName" {
  description = "ECR repo for EKS ALB Controller (only if outbound disabled + EKS)."
  value       = (var.disable_outbound_network_access && var.deployment_platform == "EKS") ? aws_ecr_repository.my_ecr_repository[0].name : ""
}

output "private_subnet_ids" {
  description = "List of IDs of private subnets"
  value = length(trimspace(var.vpc_id)) > 0 ? local.existing_private_subnet_ids : local.new_private_subnet_ids
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets"
  value = length(trimspace(var.vpc_id)) > 0 ? local.existing_public_subnet_ids : local.new_public_subnet_ids
}

###############################################################################
# Outputs (mirror the CDK CfnOutputs)
###############################################################################
output "ConfigBucketName" {
  description = "The Name of the configuration bucket"
  value       = aws_s3_bucket.config_bucket.bucket
}

output "ConfigBucketArn" {
  description = "The ARN of the configuration bucket"
  value       = aws_s3_bucket.config_bucket.arn
}

output "WafAclArn" {
  description = "The ARN of the WAF ACL"
  value       = aws_wafv2_web_acl.litellm_waf.arn
}

# ECR Repositories
data "aws_ecr_repository" "litellm" {
  name = var.ecrLitellmRepository
}

data "aws_ecr_repository" "middleware" {
  name = var.ecrMiddlewareRepository
}

output "LiteLLMRepositoryUrl" {
  description = "The URI of the LiteLLM ECR repository"
  value       = data.aws_ecr_repository.litellm.repository_url
}

output "MiddlewareRepositoryUrl" {
  description = "The URI of the Middleware ECR repository"
  value       = data.aws_ecr_repository.middleware.repository_url
}

output "DatabaseUrlSecretArn" {
  description = "The endpoint of the main database"
  value       = aws_secretsmanager_secret.db_url_secret.arn
}

output "RedisUrl" {
  description = "The Redis connection URL"
  value       = "rediss://${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
}

output "LitellmMasterAndSaltKeySecretArn" {
  description = "LiteLLM Master & Salt Key Secret ARN"
  value       = aws_secretsmanager_secret.litellm_master_salt.arn
}

output "DbSecurityGroupId" {
  description = "DB Security Group ID"
  value       = aws_security_group.db_sg.id
}

output "database_url" {
  value = "postgresql://llmproxy:${local.litellm_db_password}@${aws_db_instance.database.endpoint}/litellm"
}

output "litellm_master_key" {
  value = random_password.litellm_master.result
}

output "litellm_salt_key" {
  value = random_password.litellm_salt.result
}