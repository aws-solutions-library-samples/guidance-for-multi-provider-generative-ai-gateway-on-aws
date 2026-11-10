variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "llmgw-load"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.name_prefix))
    error_message = "name_prefix: 2-16 lowercase letters, digits or hyphens, starting with a letter (load balancer names are limited to 32 characters)."
  }
}

variable "vpc_id" {
  description = "The gateway VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets of the gateway VPC with outbound internet access (NAT): the fake upstream installs one Python package and the driver installs locust."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "subnet_ids needs at least one subnet."
  }
}

variable "gateway_security_group_id" {
  description = "Security group of the LiteLLM tasks (<deployment_name>-service-sg); only it and the driver may reach the fake upstream."
  type        = string
}

variable "gateway_url" {
  description = "Base URL of the gateway as seen from inside the VPC, for example http://internal-<alb>.elb.amazonaws.com."
  type        = string
  validation {
    condition     = can(regex("^https?://[^/]+$", var.gateway_url))
    error_message = "gateway_url: scheme and host only, no path or trailing slash."
  }
}

variable "fake_profile" {
  description = "Latency profile of the fake upstream: time to first token and inter-token delay in ms, response length range in tokens, relative jitter, tokens per SSE chunk."
  type = object({
    ttft_ms          = number
    itl_ms           = number
    tokens_min       = number
    tokens_max       = number
    jitter           = number
    tokens_per_chunk = number
  })
  default = {
    ttft_ms          = 500
    itl_ms           = 25
    tokens_min       = 100
    tokens_max       = 400
    jitter           = 0.2
    tokens_per_chunk = 1
  }
  validation {
    condition     = var.fake_profile.tokens_min >= 1 && var.fake_profile.tokens_max >= var.fake_profile.tokens_min && var.fake_profile.jitter >= 0 && var.fake_profile.jitter <= 1 && var.fake_profile.tokens_per_chunk >= 1
    error_message = "fake_profile: tokens_min >= 1, tokens_max >= tokens_min, 0 <= jitter <= 1, tokens_per_chunk >= 1."
  }
}

variable "fake_task_cpu" {
  description = "CPU units per fake upstream task (1024 = 1 vCPU); it runs two server processes per vCPU. Size it so the fake upstream does not limit the test (check its CPU in Container Insights)."
  type        = number
  default     = 2048
  validation {
    condition     = contains([1024, 2048, 4096], var.fake_task_cpu)
    error_message = "fake_task_cpu: 1024, 2048 or 4096."
  }
}

variable "fake_task_count" {
  description = "Number of fake upstream tasks."
  type        = number
  default     = 2
}

variable "driver_instance_type" {
  description = "Graviton instance type of the locust driver; run one locust process per vCPU."
  type        = string
  default     = "c7g.2xlarge"
}

variable "python_image" {
  description = "Python base image for the fake upstream (ARM64 or multi-architecture)."
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.12-slim"
}

variable "aiohttp_version" {
  description = "aiohttp version the fake upstream installs."
  type        = string
  default     = "3.14.5"
}

variable "locust_version" {
  description = "locust version the driver installs."
  type        = string
  default     = "2.47.0"
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
