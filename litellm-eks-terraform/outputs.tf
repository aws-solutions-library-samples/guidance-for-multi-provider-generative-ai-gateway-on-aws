# output "vpc" {
#   description = "Amazon VPC full configuration"
#   value       = module.vpc
# }

output "eks" {
  description = "Amazon EKS Cluster full configuration"
  value       = var.create_cluster ? aws_eks_cluster.this[0] : null
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${local.cluster_name}"
}

# Outputs matching the CDK configuration
output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = local.cluster_name
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster"
  value       = local.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = local.cluster_security_group_id
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = local.cluster_name
}

output "eks_deployment_name" {
  description = "Name of the Kubernetes deployment"
  value       = kubernetes_deployment.litellm.metadata[0].name
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = data.aws_subnets.public.ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = data.aws_subnets.private.ids
}

output "litellm_url" {
  description = "The URL for the LiteLLM service"
  value       = "https://${aws_route53_record.litellm.name}"
}