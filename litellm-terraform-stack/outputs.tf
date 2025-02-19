output "LitellmEcsCluster" {
  value       = try(module.ecs_cluster[0].LitellmEcsCluster, "")
  description = "Name of the ECS Cluster"
}

output "LitellmEcsTask" {
  value       = try(module.ecs_cluster[0].LitellmEcsTask, "")
  description = "Name of the ECS Service"
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = try(module.eks_cluster[0].eks_cluster_name, "")
}

output "eks_deployment_name" {
  description = "Name of the Kubernetes deployment"
  value       = try(module.eks_cluster[0].eks_deployment_name, "")
}

output "ServiceURL" {
  description = "Equivalent to https://var.domainName"
  value       = "https://${var.domain_name}"
}