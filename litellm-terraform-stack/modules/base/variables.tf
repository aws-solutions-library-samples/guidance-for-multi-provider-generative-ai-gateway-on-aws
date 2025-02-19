variable "vpc_id" {
  type      = string
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

variable "name" {
  type    = string
  description = "Used for tagging resources with stack-id."
}

variable "ecrLitellmRepository" {
  type        = string
  description = "Name of the LiteLLM ECR repository"
}

variable "ecrMiddlewareRepository" {
  type        = string
  description = "Name of the Middleware ECR repository"
}

variable "publicLoadBalancer" {
  type        = bool
  description = "If true, use existing public hosted zone; if false, create private hosted zone"
}

variable "hostedZoneName" {
  type        = string
  description = "Hosted Zone Name (e.g., 'example.com')"
}