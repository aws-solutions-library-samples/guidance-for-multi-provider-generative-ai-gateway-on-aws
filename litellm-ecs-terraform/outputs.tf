###############################################################################
# (12) Outputs
###############################################################################
output "LitellmEcsCluster" {
  value       = aws_ecs_cluster.this.name
  description = "Name of the ECS Cluster"
}

output "LitellmEcsTask" {
  value       = aws_ecs_service.litellm_service.name
  description = "Name of the ECS Service"
}

output "ServiceURL" {
  description = "Equivalent to https://var.domainName"
  value       = "https://${var.domain_name}"
}