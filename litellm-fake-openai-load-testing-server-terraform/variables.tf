# Variables definition
variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the SSL certificate"
  type        = string
}

variable "hosted_zone_name" {
  description = "Name of the hosted zone"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the service"
  type        = string
}

variable "ecr_fake_server_repository" {
  description = "Name of the ECR repository"
  type        = string
}

variable "architecture" {
  description = "CPU architecture (x86 or arm)"
  type        = string
}