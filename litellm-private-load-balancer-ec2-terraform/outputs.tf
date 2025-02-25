# Output the instance ID
output "linux_instance_id" {
  value       = aws_instance.linux_instance.id
  description = "Linux EC2 Instance ID"
}