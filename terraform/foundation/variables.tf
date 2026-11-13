# Foundation: long-lived network + data. Nothing in this root module may
# reference ECS, the ALB, or any other app concept.

variable "deployment_name" {
  description = "Name prefix for every resource. Two deployments in one account must use different names."
  type        = string

  validation {
    condition     = can(regex("^[a-z](-?[a-z0-9])*$", var.deployment_name)) && length(var.deployment_name) <= 20
    error_message = "deployment_name must start with a lowercase letter, contain only lowercase letters, digits and single hyphens, end with a letter or digit, and be at most 20 characters, so it can prefix S3 bucket, secret, database and cache identifiers."
  }
}

variable "tags" {
  description = "Customer tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "Bring-your-own VPC ID. Leave null to create a VPC. BYO subnets are listed explicitly and validated at plan time, before anything is created (vpc-validation.tf)."
  type        = string
  default     = null

  validation {
    condition     = var.vpc_id == null ? length(var.private_subnet_ids) == 0 : length(var.private_subnet_ids) >= 2
    error_message = "With vpc_id set, list at least two private subnets in private_subnet_ids; when creating a VPC (vpc_id = null), leave private_subnet_ids empty."
  }
}

# Check only: the app creates the DNS record. Declared here so the shared
# deploy/terraform.tfvars rejects an unsupported combination before anything
# is created.
variable "hosted_zone_id" {
  description = "Only validated here (creates nothing); the app uses it for the DNS record. A hosted zone requires your own VPC (vpc_id), already associated with the zone."
  type        = string
  default     = null

  validation {
    condition     = var.hosted_zone_id == null || var.vpc_id != null
    error_message = "hosted_zone_id requires your own VPC (vpc_id): the stack creates the DNS record in your zone, and the zone must already be associated with that VPC. Without your own VPC, leave hosted_zone_id and record_name unset and use the load balancer DNS name."
  }
}

variable "private_subnet_ids" {
  description = "Bring-your-own VPC only: at least two private subnets in different Availability Zones."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Bring-your-own VPC, public mode only: public subnets in at least two Availability Zones for the internet-facing entry point."
  type        = list(string)
  default     = []

  validation {
    condition     = var.vpc_id != null || length(var.public_subnet_ids) == 0
    error_message = "public_subnet_ids is only used with a bring-your-own vpc_id; when creating a VPC, public subnets are created as needed."
  }
}

variable "public_mode" {
  description = "Shared with the app root module (one terraform.tfvars feeds both): the entry point is internet-facing, so the network needs public subnets in two Availability Zones. Foundation only validates/creates the subnets; it knows nothing about what runs in them."
  type        = bool
  default     = false

  validation {
    condition     = !(var.public_mode && var.disable_outbound_network_access)
    error_message = "public_mode needs an internet gateway; it cannot be combined with disable_outbound_network_access."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the created VPC, /22 or larger: the private subnets must hold the tasks ECS auto scaling adds and the extra tasks of a rolling deploy. Ignored for a bring-your-own VPC (which the plan also requires to be /22 or larger)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 3, 3)) && tonumber(split("/", var.vpc_cidr)[1]) <= 22
    error_message = "vpc_cidr must be an IPv4 CIDR of /22 or larger. Each private subnet gets an eighth of it and must hold the gateway tasks at their auto scaling maximum, the extra tasks of a rolling deploy, the load balancer, VPC endpoints, the database and the cache; a smaller VPC runs out of addresses when ECS scales out or redeploys."
  }
}

variable "disable_outbound_network_access" {
  description = "No-internet mode for the created VPC: no internet gateway, no NAT, AWS services through VPC endpoints only. An IdP, non-Bedrock providers and the online check of older-format licence keys are unreachable without an egress proxy; signed licence keys are verified offline."
  type        = bool
  default     = false
}

variable "create_vpc_endpoints_in_existing_vpc" {
  description = "Bring-your-own VPC only: create the VPC endpoints in it (the S3 gateway endpoint; interface endpoints follow create_interface_endpoints / disable_outbound_network_access). Leave false when the VPC already has them."
  type        = bool
  default     = false
}

variable "create_interface_endpoints" {
  description = "Create the interface VPC endpoints (Secrets Manager, ECR, CloudWatch Logs, STS, Bedrock runtime) even though the VPC has internet egress. Created automatically in no-internet mode. Each endpoint costs per hour per Availability Zone; with a NAT gateway the traffic works without them."
  type        = bool
  default     = false
}

variable "egress_proxy_configured" {
  description = "An HTTPS proxy handles outbound traffic from the private subnets. Only suppresses the no-egress warning; the proxy itself is configured on the gateway."
  type        = bool
  default     = false
}

variable "extra_data_ingress_security_group_ids" {
  description = "Extra security groups admitted to RDS and Redis, for any non-ECS client of the data stores (for example pods on an EKS cluster)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.extra_data_ingress_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))])
    error_message = "Every entry must be a security group ID (sg-...)."
  }
}

variable "extra_data_ingress_cidrs" {
  description = "Extra CIDR ranges admitted to RDS (PostgreSQL, 5432) and Redis (6379), for any non-ECS client of the data stores, from anywhere they are routed into the VPC from. Use the narrowest ranges; the stores stay private and still require their password and auth token."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.extra_data_ingress_cidrs : can(cidrnetmask(cidr))])
    error_message = "Every entry must be a valid IPv4 CIDR (for example 10.1.0.0/16)."
  }
}

variable "kms_key_arn" {
  description = "Optional customer KMS key for the database, Redis, secrets, logs and S3. Null uses AWS-managed keys."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Protects the database from deletion and keeps the buckets and the RDS PostgreSQL log group on destroy; deploy/undeploy.sh stops before any destroy while it is true. Set to false and apply before undeploying."
  type        = bool
  default     = true
}

variable "destroy_data_without_snapshot" {
  description = "Throwaway deployments only: on destroy, delete the database WITHOUT a final snapshot and delete its automated backups. Default false: every destroy leaves a final snapshot and keeps the automated backups."
  type        = bool
  default     = false
}

# --- Optional demo Client VPN (terraform/modules/vpn) ---

variable "create_vpn" {
  description = "Create the demo/test Client VPN into the VPC (mutual TLS, split tunnel, VPC range only). For testing only; use Direct Connect, Transit Gateway or your own VPN for regular access. Run deploy/setup-vpn.sh certs first for the two certificate ARNs."
  type        = bool
  default     = false
}

variable "vpn_server_certificate_arn" {
  description = "ACM ARN of the Client VPN server certificate (printed by deploy/setup-vpn.sh certs). Required when create_vpn."
  type        = string
  default     = null

  validation {
    condition     = !var.create_vpn || var.vpn_server_certificate_arn != null
    error_message = "create_vpn needs vpn_server_certificate_arn (run deploy/setup-vpn.sh certs to create and import it)."
  }
}

variable "vpn_client_root_certificate_arn" {
  description = "ACM ARN whose chain validates the VPN client certificate (printed by deploy/setup-vpn.sh certs). Required when create_vpn."
  type        = string
  default     = null

  validation {
    condition     = !var.create_vpn || var.vpn_client_root_certificate_arn != null
    error_message = "create_vpn needs vpn_client_root_certificate_arn (run deploy/setup-vpn.sh certs to create and import it)."
  }
}

variable "vpn_client_cidr" {
  description = "Address range VPN clients get (a /12 to /22 that must not overlap the VPC CIDR)."
  type        = string
  default     = "10.250.0.0/22"
}


variable "existing_master_key_secret_arn" {
  description = "Optional Secrets Manager ARN of an existing LiteLLM master key (a plain sk-... string), for example when restoring a database from a previous deployment. Null generates a new one. Terraform never reads the value."
  type        = string
  default     = null

  validation {
    condition     = var.existing_master_key_secret_arn == null || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", var.existing_master_key_secret_arn))
    error_message = "existing_master_key_secret_arn must be a Secrets Manager secret ARN (a plain-string secret, no JSON key suffix)."
  }
}

variable "existing_salt_key_secret_arn" {
  description = "Optional Secrets Manager ARN of an existing LiteLLM salt key (a plain sk-... string). LiteLLM encrypts provider credentials stored in its database with it, so a database restored from a previous deployment needs that deployment's salt key. Null generates a new one. Terraform never reads the value."
  type        = string
  default     = null

  validation {
    condition     = var.existing_salt_key_secret_arn == null || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", var.existing_salt_key_secret_arn))
    error_message = "existing_salt_key_secret_arn must be a Secrets Manager secret ARN (a plain-string secret, no JSON key suffix)."
  }
}
