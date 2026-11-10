output "fake_api_base" {
  description = "OpenAI-compatible base URL of the fake upstream, for the gateway model's api_base."
  value       = "http://${aws_lb.fake.dns_name}/v1"
}

output "driver_instance_id" {
  description = "EC2 instance of the locust driver (SSM Run Command target)."
  value       = aws_instance.driver.id
}

output "driver_security_group_id" {
  description = "Security group of the locust driver; add it to the gateway's client_security_group_ids when the gateway sets client_cidrs."
  value       = aws_security_group.driver.id
}

output "artifacts_bucket" {
  description = "Bucket holding the scenario and the results."
  value       = aws_s3_bucket.artifacts.id
}

output "api_key_secret_id" {
  description = "Secret the driver reads its gateway virtual key from."
  value       = aws_secretsmanager_secret.api_key.id
}

output "gateway_url" {
  description = "Gateway base URL the driver targets."
  value       = var.gateway_url
}

output "fake_cluster_name" {
  description = "ECS cluster of the fake upstream."
  value       = aws_ecs_cluster.this.name
}

output "name_prefix" {
  description = "Prefix of every resource, model and key of this load test."
  value       = var.name_prefix
}
