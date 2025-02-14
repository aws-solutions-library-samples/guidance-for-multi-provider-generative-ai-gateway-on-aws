output "developers_role_arn" {
  value       = aws_iam_role.eks_developers.arn
  description = "ARN of the EKS developers IAM role"
}

output "operators_role_arn" {
  value       = aws_iam_role.eks_operators.arn
  description = "ARN of the EKS operators IAM role"
}

output "nodegroup_role_arn" {
  value       = aws_iam_role.eks_nodegroup.arn
  description = "ARN of the EKS node group IAM role"
}