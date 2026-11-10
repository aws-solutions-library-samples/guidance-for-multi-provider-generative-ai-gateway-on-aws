variable "config_bucket_name" {
  description = "Bucket the rendered LiteLLM config is uploaded to."
  type        = string
}

variable "config_object_key" {
  description = "Content-addressed key of the rendered config (config-<sha16>.yaml)."
  type        = string
}

variable "config_content" {
  description = "The rendered LiteLLM config (YAML). It holds no secrets: those reach the tasks as Secrets Manager ARNs."
  type        = string
}

variable "region" {
  description = "AWS region of the bucket and the ECS cluster."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster the migration task runs in."
  type        = string
}

variable "migrate_task_definition_arn" {
  description = "ARN of the one-off migration task definition."
  type        = string
}

variable "migrate_task_definition_revision" {
  description = "Revision of the migration task definition; a new revision re-runs the migration."
  type        = number
}

variable "image" {
  description = "Container image of the gateway; a new image re-runs the migration."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the migration task."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for the migration task (they must grant database access)."
  type        = list(string)
}
