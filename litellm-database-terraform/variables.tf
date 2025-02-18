variable "vpc_id" {
  type      = string
  default   = ""
  description = "If set, use this VPC instead of creating a new one. Leave empty to create a new VPC."
}

variable "deployment_platform" {
  type    = string
  description = "Either 'ECS' or 'EKS'."
}

variable "disable_outbound_network_access" {
  type    = bool
  description = "If true, NAT Gateways = 0 and private subnets will be fully isolated."
}

variable "create_vpc_endpoints_in_existing_vpc" {
  type    = bool
  description = "If using an existing VPC, set this to true to also create interface/gateway endpoints within it."
}

# This replicates the 'stackName' used in the CDK for tagging and outputs
variable "stack_name" {
  type    = string
  description = "Used for tagging resources with stack-id."
}

variable "region" {
  description = "AWS Region where resources will be deployed."
  type        = string
}