output "endpoint_id" {
  description = "ID of the Client VPN endpoint."
  value       = aws_ec2_client_vpn_endpoint.vpn.id
}

output "security_group_id" {
  description = "Security group of the Client VPN ENIs; allow it as a source on the ALB security group."
  value       = aws_security_group.vpn.id
}

output "ssm_parameter_name" {
  description = "SSM parameter holding the endpoint ID (read by deploy/setup-vpn.sh profile)."
  value       = aws_ssm_parameter.endpoint_id.name
}
