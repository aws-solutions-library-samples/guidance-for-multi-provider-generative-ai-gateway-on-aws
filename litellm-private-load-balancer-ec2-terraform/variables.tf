# Variables
variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "key_pair_name" {
  description = "The name of the key pair to use for SSH access"
  type        = string
}