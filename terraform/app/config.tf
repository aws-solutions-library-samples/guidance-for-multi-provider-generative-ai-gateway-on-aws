# The LiteLLM config.yaml, rendered by Terraform (no yq, no in-place edits).
# Layer 2 of 3: tfvars (infrastructure) -> this file (base config, read from S3
# at task start) -> LiteLLM's database (models, teams, keys, budgets — the UI).
# The object key carries the content hash (config-<sha16>.yaml) and the task
# definition names that key (container.tf), so a config change rolls the tasks
# and every revision keeps loading the config it was deployed with.

data "aws_region" "current" {}

locals {
  override = yamldecode(var.config_override_file != null ? file(var.config_override_file) : "{}")

  base_config = yamldecode(templatefile("${path.module}/templates/config-base.yaml.tftpl", {
    trusted_proxy_ranges = [var.vpc_cidr]
    request_log_bucket   = local.request_log_bucket_name
    region               = data.aws_region.current.region
  }))

  # Customer override: every top-level key passes through (guardrails,
  # credential_list, mcp_servers, ...); model_list comes from the override and
  # the *_settings maps are merged key-by-key over the base.
  litellm_config = merge(
    local.base_config,
    local.override,
    {
      model_list       = try(local.override.model_list, [])
      general_settings = merge(local.base_config.general_settings, try(local.override.general_settings, {}))
      litellm_settings = merge(local.base_config.litellm_settings, try(local.override.litellm_settings, {}))
      router_settings  = merge(local.base_config.router_settings, try(local.override.router_settings, {}))
    },
  )

  litellm_config_yaml = yamlencode(local.litellm_config)
  config_sha          = sha256(local.litellm_config_yaml)
  config_object_key   = "config-${substr(local.config_sha, 0, 16)}.yaml"
}

# The rendered config, held in state so the plan shows its diff. It contains no
# secrets: those reach the tasks as Secrets Manager ARNs. module.rollout
# (ecs.tf) uploads it to its own key and never deletes earlier keys.
resource "terraform_data" "litellm_config" {
  input = {
    key     = local.config_object_key
    content = local.litellm_config_yaml
  }
}

# Plan-time warnings (not errors): risky settings the plan should call out.

check "debug_logging_is_temporary" {
  assert {
    condition     = var.log_level != "DEBUG"
    error_message = "log_level = DEBUG writes every prompt and response to CloudWatch. Use it for temporary troubleshooting only, then set it back to INFO."
  }
}

check "enterprise_settings_need_licence" {
  assert {
    condition     = var.litellm_license_secret_arn != null || !can(local.litellm_config.general_settings.enable_jwt_auth)
    error_message = "enable_jwt_auth is an Enterprise feature: without litellm_license_secret_arn LiteLLM answers 403 to JWTs."
  }
}

check "public_mode_without_identity_provider" {
  assert {
    condition     = !(var.public_mode && var.identity_provider == null)
    error_message = <<-EOT
      PUBLIC MODE WITHOUT AN IDENTITY PROVIDER.
      The LiteLLM admin UI will be reachable from the internet protected only by
      the UI password and WAF. The UI can create keys, change models and read
      spend for every team.
      Fix: configure identity_provider, so the ALB requires sign-in in front of
      the UI paths (API paths keep LiteLLM key authentication).
      To proceed deliberately without it, apply this plan as is; this warning
      does not block the deployment and repeats on every plan.
    EOT
  }
}

check "identity_provider_needs_outbound_access" {
  assert {
    condition     = !(var.identity_provider != null && var.disable_outbound_network_access)
    error_message = "identity_provider is set but the network has no outbound internet access (disable_outbound_network_access): the ALB cannot reach the IdP's token and user-info endpoints, so every UI sign-in will fail. Provide a route to the IdP (NAT, or a private IdP endpoint) or remove identity_provider."
  }
}

check "db_unavailable_requests_not_allowed" {
  assert {
    condition     = try(local.litellm_config.general_settings.allow_requests_on_db_unavailable, false) != true
    error_message = "config_override_file sets general_settings.allow_requests_on_db_unavailable: true. During a database outage LiteLLM then admits ANY presented key, including invalid ones, without budgets. LiteLLM virtual keys are this gateway's only API authentication, so every database failover becomes an unauthenticated window. Remove the setting unless another layer authenticates every caller."
  }
}

