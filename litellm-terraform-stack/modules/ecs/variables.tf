variable "name" {
  description = "Standard name to be used as prefix on all resources."
  type        = string
}

# Variables needed for the configuration
variable "config_bucket_arn" {
  description = "ARN of the configuration bucket"
  type        = string
}

variable "log_bucket_arn" {
  description = "ARN of the log bucket"
  type        = string
}

# Required variables
variable "ecr_litellm_repository_url" {
  description = "URL of the ECR repository for LiteLLM"
  type        = string
}

variable "ecr_middleware_repository_url" {
  description = "URL of the ECR repository for middleware"
  type        = string
}

variable "litellm_version" {
  description = "Version tag for LiteLLM image"
  type        = string
}

variable "config_bucket_name" {
  description = "Name of the S3 bucket containing config"
  type        = string
}

variable "redis_host" {
  description = "The Redis host name"
  type        = string
}

variable "redis_port" {
  description = "The Redis port"
  type        = string
}

variable "redis_password" {
  description = "The Redis password"
  type        = string
}

variable "openai_api_key" {
  description = "OpenAI API key"
  type        = string
  sensitive   = true
}

variable "azure_openai_api_key" {
  description = "Azure OpenAI API key"
  type        = string
  sensitive   = true
}

variable "azure_api_key" {
  description = "Azure API key"
  type        = string
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Anthropic API key"
  type        = string
  sensitive   = true
}

variable "groq_api_key" {
  description = "Groq API key"
  type        = string
  sensitive   = true
}

variable "cohere_api_key" {
  description = "Cohere API key"
  type        = string
  sensitive   = true
}

variable "co_api_key" {
  description = "Co API key"
  type        = string
  sensitive   = true
}

variable "hf_token" {
  description = "HuggingFace token"
  type        = string
  sensitive   = true
}

variable "huggingface_api_key" {
  description = "HuggingFace API key"
  type        = string
  sensitive   = true
}

variable "databricks_api_key" {
  description = "Databricks API key"
  type        = string
  sensitive   = true
}

variable "gemini_api_key" {
  description = "Gemini API key"
  type        = string
  sensitive   = true
}

variable "codestral_api_key" {
  description = "Codestral API key"
  type        = string
  sensitive   = true
}

variable "mistral_api_key" {
  description = "Mistral API key"
  type        = string
  sensitive   = true
}

variable "azure_ai_api_key" {
  description = "Azure AI API key"
  type        = string
  sensitive   = true
}

variable "nvidia_nim_api_key" {
  description = "NVIDIA NIM API key"
  type        = string
  sensitive   = true
}

variable "xai_api_key" {
  description = "XAI API key"
  type        = string
  sensitive   = true
}

variable "perplexityai_api_key" {
  description = "PerplexityAI API key"
  type        = string
  sensitive   = true
}

variable "github_api_key" {
  description = "GitHub API key"
  type        = string
  sensitive   = true
}

variable "deepseek_api_key" {
  description = "Deepseek API key"
  type        = string
  sensitive   = true
}

variable "ai21_api_key" {
  description = "AI21 API key"
  type        = string
  sensitive   = true
}

variable "langsmith_api_key" {
  description = "Langsmith API key"
  type        = string
  sensitive   = true
}

variable "langsmith_project" {
  description = "Langsmith project"
  type        = string
}

variable "langsmith_default_run_name" {
  description = "langsmith default run name"
  type        = string
}

variable "okta_audience" {
  description = "Okta audience"
  type        = string
}

variable "okta_issuer" {
  description = "Okta issuer"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate"
  type        = string
}

variable "wafv2_acl_arn" {
  description = "ARN of the WAFv2 ACL"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the ingress"
  type        = string
}

variable "hosted_zone_name" {
  description = "Hosted zone name for the ingress"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster and nodes will be deployed"
  type        = string
}

variable "db_security_group_id" {
  description = "RDS db security group id"
  type        = string
}

variable "redis_security_group_id" {
  description = "redis security group id"
  type        = string
}

variable "architecture" {
  description = "The architecture for the node group instances (x86 or arm64)"
  type        = string
  validation {
    condition     = contains(["x86", "arm"], var.architecture)
    error_message = "Architecture must be either 'x86' or 'arm64'."
  }
}

variable "disable_outbound_network_access" {
    description = "Whether to disable outbound network access for the EKS Cluster"
    type = bool
}

variable "desired_capacity" {
  description = "Desired Capacity on the node group and deployment"
  type = number
}

variable "min_capacity" {
  description = "Min Capacity on the node group"
  type = number
}

variable "max_capacity" {
  description = "Max Capacity on the node group"
  type = number
}

variable "public_load_balancer" {
  description = "whether the load balancer is public"
  type = bool
}

variable "master_and_salt_key_secret_arn" {
  description = "ARN of secret with master and salt key"
  type = string
}

variable "main_db_secret_arn" {
  description = "ARN of secret for main rds db"
  type = string
}

variable "vcpus" {
  description = "Number of ECS vcpus"
  type = number
}

variable "cpu_target_utilization_percent" {
  description = "CPU target utilization percent for autoscale"
  type = number
}

variable "memory_target_utilization_percent" {
  description = "Memory target utilization percent for autoscale"
  type = number
}

variable "private_subnets" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "public_subnets" {
  description = "List of public subnet IDs"
  type        = list(string)
}
