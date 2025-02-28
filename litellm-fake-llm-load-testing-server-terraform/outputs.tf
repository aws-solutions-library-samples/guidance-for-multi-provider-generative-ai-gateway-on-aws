# Outputs
output "fake_server_ecs_cluster" {
  value       = aws_ecs_cluster.fake_llm_cluster.name
  description = "Name of the ECS Cluster"
}

output "fake_server_ecs_task" {
  value       = aws_ecs_service.fake_server_service.name
  description = "Name of the task service"
}

output "fake_server_service_url" {
  value       = "https://${var.fake_llm_load_testing_endpoint_record_name}"
  description = "URL of the deployed service"
}
