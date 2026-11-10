# A Strands agent on Amazon Bedrock AgentCore Runtime that reaches models
# through the LiteLLM gateway:
#
#   - the runtime runs in the gateway's VPC (VPC network mode) so it reaches a
#     private gateway, and its security group allows only the gateway port
#     towards the gateway and HTTPS towards AWS APIs;
#   - the agent authenticates with its own LiteLLM virtual key, held by
#     AgentCore Identity (an API-key credential provider backed by a Secrets
#     Manager secret this module creates). scripts/agent-key.sh creates the key
#     through the gateway's API and writes it into the secret, and revokes it
#     on destroy, so the key does not pass through variables or state;
#   - the runtime role has no Amazon Bedrock permissions.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  gateway_ca_file = var.gateway_ca_certificate_file != null ? abspath(var.gateway_ca_certificate_file) : ""
  gateway_ca_pem  = var.gateway_ca_certificate_file != null ? base64encode(file(var.gateway_ca_certificate_file)) : null

  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.region
  partition    = data.aws_partition.current.partition
  runtime_name = replace(var.name, "-", "_") # AgentCore runtime names allow [a-zA-Z0-9_]
  key_alias    = var.name                    # the agent's virtual key alias in LiteLLM

  # An explicit port in the URL, else the scheme's default.
  gateway_port = try(tonumber(regex(":([0-9]+)$", var.gateway_url)[0]), startswith(var.gateway_url, "https://") ? 443 : 80)
}

# --- The agent's virtual key, held by AgentCore Identity ---

locals {
  # The /key/generate request of the agent's virtual key: limited to the
  # agent's model, with its own budget and rate limits.
  key_request = {
    key_alias       = local.key_alias
    models          = [var.model_id]
    max_budget      = var.key_max_budget
    budget_duration = var.key_budget_duration
    rpm_limit       = var.key_rpm_limit
    tpm_limit       = var.key_tpm_limit
    metadata = {
      agentcore_runtime_name = local.runtime_name
      created_by             = "examples/agentcore"
    }
  }
}

resource "aws_secretsmanager_secret" "gateway_key" {
  name        = "${var.name}-gateway-key"
  description = "LiteLLM virtual key of the ${var.name} agent, as {\"api_key\": ...}. Written by scripts/agent-key.sh; read through AgentCore Identity."

  # The key is revoked in LiteLLM when the stack is destroyed, so there is
  # nothing to recover; immediate deletion lets the same name be redeployed.
  recovery_window_in_days = 0
}

# The key lives in LiteLLM, which has no resource in this stack's providers,
# so its lifecycle is a provisioner pair on the operator's machine (which must
# reach the gateway): create before the credential provider, which requires a
# value in the secret; revoke on destroy. A change to the key's settings
# replaces it, i.e. rotates the key. SKIP_KEY_REVOCATION=1 in the environment
# of `terraform destroy` skips the revocation (for an unreachable gateway).
# The script runs from this directory by a relative path, so neither the state
# nor the command depends on where the checkout lives.
resource "terraform_data" "gateway_key" {
  triggers_replace = [aws_secretsmanager_secret.gateway_key.arn, local.key_request, var.gateway_url]

  input = {
    gateway_url           = var.gateway_url
    master_key_secret_arn = var.master_key_secret_arn
    key_secret_arn        = aws_secretsmanager_secret.gateway_key.arn
    key_request           = jsonencode(local.key_request)
    ca_file               = local.gateway_ca_file
  }

  provisioner "local-exec" {
    working_dir = path.module
    command     = "bash \"../scripts/agent-key.sh\" create"
    environment = {
      AGENT_KEY_GATEWAY_URL           = self.input.gateway_url
      AGENT_KEY_MASTER_KEY_SECRET_ARN = self.input.master_key_secret_arn
      AGENT_KEY_SECRET_ARN            = self.input.key_secret_arn
      AGENT_KEY_REQUEST               = self.input.key_request
      AGENT_KEY_CA_FILE               = self.input.ca_file
    }
  }

  provisioner "local-exec" {
    when        = destroy
    working_dir = path.module
    command     = "bash \"../scripts/agent-key.sh\" delete"
    environment = {
      AGENT_KEY_GATEWAY_URL           = self.input.gateway_url
      AGENT_KEY_MASTER_KEY_SECRET_ARN = self.input.master_key_secret_arn
      AGENT_KEY_SECRET_ARN            = self.input.key_secret_arn
      AGENT_KEY_REQUEST               = self.input.key_request
      AGENT_KEY_CA_FILE               = self.input.ca_file
    }
  }
}

resource "aws_bedrockagentcore_api_key_credential_provider" "gateway" {
  name                  = "${var.name}-gateway"
  api_key_secret_source = "EXTERNAL"

  api_key_secret_config {
    secret_id = aws_secretsmanager_secret.gateway_key.arn
    json_key  = "api_key"
  }

  depends_on = [terraform_data.gateway_key]
}

# --- Code bundle (direct code deployment: no container image) ---

resource "aws_s3_bucket" "code" {
  bucket        = "${var.name}-code-${local.account_id}-${local.region}"
  force_destroy = true # holds build artefacts only
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "code" {
  bucket = aws_s3_bucket.code.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "code_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.code.arn,
      "${aws_s3_bucket.code.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "code" {
  bucket = aws_s3_bucket.code.id
  policy = data.aws_iam_policy_document.code_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.code]
}

# Content-addressed: a rebuilt bundle with changed sources gets a new key,
# which updates the runtime to a new version.
resource "aws_s3_object" "code" {
  bucket = aws_s3_bucket.code.id
  key    = "agent/${filesha256(var.code_zip_path)}.zip"
  source = var.code_zip_path

  # The runtime moves to the new bundle before the old one is deleted.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.code]
}

# --- Network ---

resource "aws_security_group" "runtime" {
  name        = "${var.name}-runtime"
  description = "AgentCore Runtime of ${var.name}: the gateway and AWS APIs only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-runtime" }
}

resource "aws_vpc_security_group_egress_rule" "gateway" {
  security_group_id = aws_security_group.runtime.id
  description       = "LLM gateway"
  cidr_ipv4         = var.gateway_cidr
  ip_protocol       = "tcp"
  from_port         = local.gateway_port
  to_port           = local.gateway_port
}

# AgentCore Identity, CloudWatch Logs and the code bundle download are AWS
# endpoints reached through the VPC's NAT gateway or interface endpoints.
resource "aws_vpc_security_group_egress_rule" "aws_apis" {
  security_group_id = aws_security_group.runtime.id
  description       = "AWS APIs over HTTPS (NAT gateway or VPC endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# --- Runtime ---

resource "aws_bedrockagentcore_agent_runtime" "agent" {
  agent_runtime_name = local.runtime_name
  description        = "Strands agent doing all LLM inference through the LiteLLM gateway"
  role_arn           = aws_iam_role.runtime.arn

  agent_runtime_artifact {
    code_configuration {
      entry_point = ["main.py"]
      runtime     = "PYTHON_3_13"
      code {
        s3 {
          bucket = aws_s3_object.code.bucket
          prefix = aws_s3_object.code.key
        }
      }
    }
  }

  environment_variables = merge(
    {
      GATEWAY_BASE_URL    = var.gateway_url
      MODEL_ID            = var.model_id
      CREDENTIAL_PROVIDER = aws_bedrockagentcore_api_key_credential_provider.gateway.name
      MAX_TOKENS          = tostring(var.max_tokens)
    },
    # A CA certificate is public, so it is a plain value; base64 because runtime
    # environment values may not contain newlines.
    local.gateway_ca_pem != null ? { GATEWAY_CA_PEM_BASE64 = local.gateway_ca_pem } : {},
  )

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = var.subnet_ids
      security_groups = [aws_security_group.runtime.id]
    }
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  # The role's policy must be in place before the runtime starts and fetches
  # its code and the gateway key.
  depends_on = [aws_iam_role_policy.runtime]
}
