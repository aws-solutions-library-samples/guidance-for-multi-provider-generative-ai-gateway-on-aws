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

output "DatabaseMiddlewareUrlSecretArn" {
  description = "The endpoint of the middleware database"
  value       = aws_secretsmanager_secret.db_middleware_url_secret.arn
}

output "RedisUrl" {
  description = "The Redis connection URL"
  value       = "redis://${var.redisHostName}:${var.redisPort}"
}

output "LitellmMasterAndSaltKeySecretArn" {
  description = "LiteLLM Master & Salt Key Secret ARN"
  value       = aws_secretsmanager_secret.litellm_master_salt.arn
}

output "DbSecurityGroupId" {
  description = "DB Security Group ID"
  value       = data.aws_security_group.db.id
}

output "RedisSecurityGroupId" {
  description = "Redis Security Group ID"
  value       = data.aws_security_group.redis.id
}

output "VpcId" {
  description = "The ID of the VPC"
  value       = data.aws_vpc.this.id
}

output "ServiceURL" {
  description = "Equivalent to https://var.domainName"
  value       = "https://${var.domainName}"
}