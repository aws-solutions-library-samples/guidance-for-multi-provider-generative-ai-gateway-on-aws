# Inputs of the example. Gateway values are plain variables (copy them from the
# gateway's `terraform output`); this root module never reads or changes the
# gateway's own state or resources.

variable "name" {
  description = "Name prefix of every resource of this agent. Lower-case letters, digits and hyphens; the AgentCore runtime name uses underscores in place of hyphens."
  type        = string
  default     = "llmgw-agent-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.name))
    error_message = "name must be 3-30 characters: a lower-case letter, then lower-case letters, digits or hyphens."
  }
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}

# --- The gateway (outputs of the gateway deployment) ---

variable "gateway_url" {
  description = "Gateway app output service_url, for example https://llm.example.com. The agent calls <gateway_url>/v1."
  type        = string

  validation {
    condition     = can(regex("^https?://[^/]+$", var.gateway_url))
    error_message = "gateway_url must be http(s)://host[:port] with no path or trailing slash."
  }
}

variable "gateway_ca_certificate_file" {
  description = "Optional PEM file of the certificate authority that issued the gateway's certificate, for a gateway with a private CA. The agent and scripts/agent-key.sh trust it in addition to the public roots. Absolute, or relative to examples/agentcore/terraform."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_ca_certificate_file == null || can(regex("-----BEGIN CERTIFICATE-----", file(var.gateway_ca_certificate_file)))
    error_message = "gateway_ca_certificate_file must be a readable PEM file with at least one certificate."
  }
}

variable "master_key_secret_arn" {
  description = "Gateway foundation output master_key_secret_arn. Read only by scripts/agent-key.sh, on the operator's machine, to create and delete the agent's virtual key; the agent does not receive it."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:", var.master_key_secret_arn))
    error_message = "master_key_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "vpc_id" {
  description = "Gateway foundation output vpc_id. The runtime runs in this VPC so it reaches a private gateway."
  type        = string
}

variable "subnet_ids" {
  description = "Gateway foundation output private_subnet_ids (subnets with a route to AWS APIs, through NAT or VPC endpoints). They must be in Availability Zones AgentCore Runtime supports."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "Give at least one subnet."
  }
}

variable "gateway_cidr" {
  description = "CIDR the gateway's load balancer is in (the foundation output vpc_cidr). The runtime may reach it on the gateway port only."
  type        = string

  validation {
    condition     = can(cidrhost(var.gateway_cidr, 0))
    error_message = "gateway_cidr must be a valid IPv4 CIDR."
  }
}

# --- The agent ---

variable "model_id" {
  description = "Model name, as registered in the gateway, the agent uses. The agent's virtual key is limited to this model."
  type        = string
}

variable "max_tokens" {
  description = "Output-token cap per model call."
  type        = number
  default     = 1024
}

variable "code_zip_path" {
  description = "Path of the code bundle built by scripts/build.sh."
  type        = string
  default     = "../build/agent.zip"
}

# --- The agent's virtual key (created by scripts/agent-key.sh) ---

variable "key_max_budget" {
  description = "Spend limit of the agent's virtual key, in USD, reset every key_budget_duration."
  type        = number
  default     = 5
}

variable "key_budget_duration" {
  description = "Budget reset period of the virtual key (LiteLLM duration, for example 30d)."
  type        = string
  default     = "30d"
}

variable "key_rpm_limit" {
  description = "Requests-per-minute limit of the virtual key."
  type        = number
  default     = 30
}

variable "key_tpm_limit" {
  description = "Tokens-per-minute limit of the virtual key."
  type        = number
  default     = 100000
}
