variable "name" {
  description = "Standard name to be used as prefix on all resources."
  type        = string
  default     = "genai-gateway"
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