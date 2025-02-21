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

variable "create_private_hosted_zone_in_existing_vpc" {
  description = "In the case public_load_balancer=false (meaning we need a private hosted zone), and an vpc_id is provided, decides whether we create a private hosted zone, or assume one already exists and import it"
  type        = bool
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