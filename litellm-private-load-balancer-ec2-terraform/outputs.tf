# Output the instance ID
output "linux_instance_id" {
  value       = aws_instance.linux_instance.id
  description = "Linux EC2 Instance ID"
}

# Output the public IP address
output "bastion_host_public_ip" {
  value       = aws_instance.linux_instance.public_ip
  description = "Public IP address of the Linux EC2 Instance"
}
