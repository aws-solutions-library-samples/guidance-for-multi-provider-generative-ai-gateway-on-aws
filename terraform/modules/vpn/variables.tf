variable "deployment_name" {
  description = "Name prefix for every resource (the foundation deployment_name)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.deployment_name))
    error_message = "deployment_name must start with a lowercase letter and contain only lowercase letters, digits and hyphens (max 20 characters)."
  }
}

variable "tags" {
  description = "Extra tags merged into every taggable resource (the provider's default_tags apply on top)."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "ID of the gateway VPC the Client VPN endpoint attaches to."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-...)."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR of the gateway VPC. Used for the authorisation rule, the security group egress and the VPC DNS resolver (base + 2)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 2))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs to associate with the endpoint (at most one per Availability Zone; each association is billed hourly)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet ID is required."
  }
}

variable "client_cidr" {
  description = "IPv4 range VPN clients get addresses from. AWS requires a prefix between /12 and /22; it must not overlap the VPC CIDR."
  type        = string
  default     = "10.250.0.0/22"

  validation {
    condition = (
      can(cidrnetmask(var.client_cidr)) &&
      try(tonumber(split("/", var.client_cidr)[1]) >= 12 && tonumber(split("/", var.client_cidr)[1]) <= 22, false)
    )
    error_message = "client_cidr must be a valid IPv4 CIDR with a prefix length between /12 and /22 (AWS Client VPN requirement)."
  }

  validation {
    condition = !try(
      cidrsubnet("${split("/", var.client_cidr)[0]}/${split("/", var.vpc_cidr)[1]}", 0, 0) == cidrsubnet(var.vpc_cidr, 0, 0) ||
      cidrsubnet("${split("/", var.vpc_cidr)[0]}/${split("/", var.client_cidr)[1]}", 0, 0) == cidrsubnet(var.client_cidr, 0, 0),
      false
    )
    error_message = "client_cidr must not overlap the VPC CIDR."
  }
}

variable "server_certificate_arn" {
  description = "ACM ARN of the imported server certificate (created by deploy/setup-vpn.sh certs)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$", var.server_certificate_arn))
    error_message = "server_certificate_arn must be an ACM certificate ARN."
  }
}

variable "client_root_certificate_arn" {
  description = "ACM ARN whose chain validates client certificates (created by deploy/setup-vpn.sh certs)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$", var.client_root_certificate_arn))
    error_message = "client_root_certificate_arn must be an ACM certificate ARN."
  }
}

variable "egress_ports" {
  description = "TCP ports VPN clients may reach inside the VPC (the ALB listens on 443; add 80 for an allow_insecure_http trial)."
  type        = list(number)
  default     = [443]

  validation {
    condition     = alltrue([for p in var.egress_ports : p >= 1 && p <= 65535])
    error_message = "Every egress port must be between 1 and 65535."
  }
}

variable "session_timeout_hours" {
  description = "Maximum VPN session duration in hours (AWS allows 8, 10, 12 or 24)."
  type        = number
  default     = 8

  validation {
    condition     = contains([8, 10, 12, 24], var.session_timeout_hours)
    error_message = "session_timeout_hours must be one of 8, 10, 12 or 24."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the connection log group (3653 = ten years)."
  type        = number
  default     = 3653

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the retention values CloudWatch Logs supports."
  }
}

variable "kms_key_arn" {
  description = "Optional customer KMS key to encrypt the connection log group. Null uses CloudWatch Logs default encryption."
  type        = string
  default     = null
}
