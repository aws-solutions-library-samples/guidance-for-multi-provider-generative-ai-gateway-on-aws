variable "deployment_platform" {
  description = "Which platform to deploy (ECS or EKS)"
  type        = string
  
  validation {
    condition     = can(regex("^(ECS|EKS)$", upper(var.deployment_platform)))
    error_message = "DEPLOYMENT_PLATFORM must be either 'ECS' or 'EKS' (case insensitive)."
  }
}

locals {
  platform = upper(var.deployment_platform)
}

# ECS and EKS Variables

variable "name" {
  description = "Standard name to be used as prefix on all resources."
  type        = string
  default     = "genai-gateway"
}

variable "vpc_id" {
  type      = string
  default   = ""
  description = "If set, use this VPC instead of creating a new one. Leave empty to create a new VPC."
}

variable "log_bucket_arn" {
  description = "ARN of the log bucket"
  type        = string
}

variable "litellm_version" {
  description = "Version tag for LiteLLM image"
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

variable "domain_name" {
  description = "Domain name for the ingress"
  type        = string
}

variable "hosted_zone_name" {
  description = "Hosted zone name for the ingress"
  type        = string
}

variable "architecture" {
  description = "The architecture for the node group instances (x86 or arm64)"
  type        = string
  default     = "x86"
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

//ECS Only Variables
variable "cpu_target_utilization_percent" {
  description = "CPU target utilization percent for autoscale"
  type = number
}

variable "memory_target_utilization_percent" {
  description = "Memory target utilization percent for autoscale"
  type = number
}

variable "vcpus" {
  description = "Number of ECS vcpus"
  type = number
}

# EKS Only Variables
variable "existing_cluster_name" {
  description = "Name of the existing EKS Cluster."
  type        = string
  default     = ""
}

variable "cluster_version" {
  description = "Kubernetes version for Amazon EKS Cluster."
  type        = string
  default     = "1.32"
}

variable "create_cluster" {
  description = "Controls if EKS cluster should be created"
  type        = bool
}

variable "install_add_ons_in_existing_eks_cluster" {
  description = "Whether to install add ons onto an existing EKS Cluster"
  type = bool
}

variable "arm_instance_type" {
  description = "Instance type for arm deployment"
  type = string
}

variable "x86_instance_type" {
  description = "Instance type for x86 deployment"
  type = string
}

variable "arm_ami_type" {
  description = "AMI type for arm deployment"
  type = string
}

variable "x86_ami_type" {
  description = "AMI type for x86 deployment"
  type = string
}

variable "create_vpc_endpoints_in_existing_vpc" {
  type    = bool
  description = "If using an existing VPC, set this to true to also create interface/gateway endpoints within it."
}

variable "ecrLitellmRepository" {
  type        = string
  description = "Name of the LiteLLM ECR repository"
}

variable "ecrMiddlewareRepository" {
  type        = string
  description = "Name of the Middleware ECR repository"
}

variable "rds_instance_class" {
  type        = string
  description = "The instance class for the RDS database"
}

variable "rds_allocated_storage" {
  type        = number
  description = "The allocated storage in GB for the RDS database"
}

variable "redis_node_type" {
  type        = string
  description = "The node type for Redis clusters"
}

variable "redis_num_cache_clusters" {
  type        = number
  description = "The number of cache clusters for Redis"
}
