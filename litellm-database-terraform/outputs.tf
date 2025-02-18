#############################################
# OUTPUTS
#############################################

# The outputs replicating the cdk.CfnOutput calls:

output "RdsLitellmHostname" {
  description = "The hostname of the LiteLLM RDS instance"
  value       = aws_db_instance.database.endpoint
}

output "RdsLitellmSecretArn" {
  description = "The ARN of the LiteLLM RDS secret"
  value       = aws_secretsmanager_secret.db_secret_main.arn
}

output "RdsMiddlewareHostname" {
  description = "The hostname of the Middleware RDS instance"
  value       = aws_db_instance.database_middleware.endpoint
}

output "RdsMiddlewareSecretArn" {
  description = "The ARN of the Middleware RDS secret"
  value       = aws_secretsmanager_secret.db_secret_middleware.arn
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
  value = jsonencode(length(trimspace(var.vpc_id)) > 0 ? (length(data.aws_subnets.existing_all) > 0 ? data.aws_subnets.existing_all[0].ids : []) : local.new_private_subnet_ids)
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets"
  value = jsonencode(length(trimspace(var.vpc_id)) > 0 ? (length(data.aws_subnets.existing_all) > 0 ? data.aws_subnets.existing_all[0].ids : []) : local.new_public_subnet_ids)
}

