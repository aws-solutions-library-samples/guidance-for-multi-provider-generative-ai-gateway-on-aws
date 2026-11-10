# Key wiring of the app root module, applied against mocked providers: ALB modes,
# OIDC, WAF, the container/migration task definitions, IAM scoping and the
# rendered config. Nothing touches AWS.

# The generated mock values must pass the provider's client-side ARN validation
# where resources reference each other's ARNs.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock-role"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:loadbalancer/app/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:targetgroup/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:listener/app/mock/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:111111111111:log-group:mock"
    }
  }

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:eu-west-1:111111111111:regional/webacl/mock/00000000-0000-0000-0000-000000000000"
    }
  }

  # The observability module's policy documents and the ARNs its topic and key
  # policy reference must look real to the provider's client-side validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-west-1:111111111111:llmgw-alarms"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  deployment_name = "llmgw"
  certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"

  # Foundation outputs (wired by deploy.sh in real runs).
  vpc_id                         = "vpc-0123456789abcdef0"
  private_subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  vpc_cidr                       = "10.0.0.0/16"
  database_url_secret_arn        = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/database-url-AbCdEf"
  redis_endpoint                 = "llmgw-redis.cache.amazonaws.com"
  redis_port                     = 6379
  redis_auth_secret_arn          = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/redis-auth-AbCdEf"
  config_bucket_name             = "llmgw-config-111111111111-eu-west-1"
  master_key_secret_arn          = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/master-key-AbCdEf"
  salt_key_secret_arn            = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/salt-key-AbCdEf"
  data_ingress_security_group_id = "sg-0123456789abcdef0"
  ui_password_secret_arn         = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/ui-password-AbCdEf"
  rds_instance_identifier        = "llmgw-litellm-db"
  redis_replication_group_id     = "llmgw-redis"

  # One provider key with the :json-key:: suffix, to prove the execution role
  # grant is on the secret ARN itself.
  provider_secret_arns = {
    OPENAI_API_KEY = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/openai-AbCdEf:api_key::"
  }
}

# The config upload and the migration gate (module.rollout) call the AWS CLI
# from local-exec provisioners, which run even for an overridden resource.
# Replacing the whole module keeps every test apply away from AWS.
override_module {
  target = module.rollout
}

run "private_defaults" {
  command = apply

  assert {
    condition     = aws_lb.this.internal == true
    error_message = "Private mode must create an internal ALB."
  }

  assert {
    condition     = toset(aws_lb.this.subnets) == toset(var.private_subnet_ids)
    error_message = "The internal ALB must live in the private subnets."
  }

  assert {
    condition     = aws_lb_target_group.litellm.deregistration_delay == "120" && jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].stopTimeout == 120
    error_message = "Target deregistration delay and ECS stopTimeout (the drain window) must both be 120 s."
  }

  assert {
    condition     = aws_lb.this.idle_timeout == 600
    error_message = "The ALB idle timeout is 600 s, above the router's 360 s worst case for one non-streaming request."
  }

  assert {
    condition = (
      aws_ecs_task_definition.litellm.cpu == "2048" && aws_ecs_task_definition.litellm.memory == "4096" &&
      aws_ecs_task_definition.litellm.runtime_platform[0].cpu_architecture == "ARM64" &&
      aws_ecs_task_definition.migrate.runtime_platform[0].cpu_architecture == "ARM64"
    )
    error_message = "Gateway tasks are Graviton (ARM64) with 2 vCPU and 4 GiB."
  }

  assert {
    condition = (
      aws_ecs_service.litellm.desired_count == 2 &&
      aws_appautoscaling_policy.cpu.target_tracking_scaling_policy_configuration[0].target_value == 35 &&
      aws_appautoscaling_policy.memory.target_tracking_scaling_policy_configuration[0].target_value == 70
    )
    error_message = "Two tasks at creation; target tracking at 35 % CPU and 70 % memory."
  }

  assert {
    condition = anytrue([
      for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment :
      e.name == "KEEPALIVE_TIMEOUT" && e.value == tostring(aws_lb.this.idle_timeout + 5)
    ])
    error_message = "uvicorn keep-alive (KEEPALIVE_TIMEOUT) must be the ALB idle timeout + 5 s."
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
    error_message = "The HTTPS listener uses the restricted TLS 1.3/1.2 policy."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.retries == 10 && jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.startPeriod == 60
    error_message = "The container health check allows 10 misses after a 60 s start period."
  }

  assert {
    condition = (
      yamldecode(terraform_data.litellm_config.input.content).router_settings.timeout == 120 &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.stream_timeout == 180 &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.num_retries == 3 &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.retry_after == 0 &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.allowed_fails == 3 &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.cooldown_time == 5 &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.retry_policy == {
        AuthenticationErrorRetries         = 0
        BadRequestErrorRetries             = 0
        ContentPolicyViolationErrorRetries = 0
        RateLimitErrorRetries              = 3
        TimeoutErrorRetries                = 2
        InternalServerErrorRetries         = 1
      }
    )
    error_message = "The router must set per-attempt timeouts, retries, cooldowns and the per-error retry policy."
  }

  assert {
    condition = (
      (1 + yamldecode(terraform_data.litellm_config.input.content).router_settings.retry_policy.TimeoutErrorRetries) *
      yamldecode(terraform_data.litellm_config.input.content).router_settings.timeout < aws_lb.this.idle_timeout
    )
    error_message = "The router's worst case for one non-streaming request must fit inside the ALB idle timeout."
  }

  assert {
    condition = (
      yamldecode(terraform_data.litellm_config.input.content).litellm_settings.cache_params.ssl == true &&
      yamldecode(terraform_data.litellm_config.input.content).router_settings.redis_ssl == true &&
      yamldecode(terraform_data.litellm_config.input.content).general_settings.proxy_batch_write_at == 60
    )
    error_message = "Both Redis blocks set ssl explicitly, and spend is batch-written every 60 s."
  }

  assert {
    condition     = length(aws_lb_listener.https) == 1 && [for a in aws_lb_listener.http.default_action : a.type][0] == "redirect"
    error_message = "HTTPS must be served and plain HTTP redirected to it."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 0 && length(aws_wafv2_web_acl_association.alb) == 0
    error_message = "No WAF in private mode."
  }

  assert {
    condition     = length(aws_lb_listener_rule.ui_oidc) == 0
    error_message = "No OIDC rule without an identity provider."
  }

  assert {
    condition     = keys({ for k, v in aws_vpc_security_group_ingress_rule.alb : k => v }) == ["10.0.0.0/16-443", "10.0.0.0/16-80"]
    error_message = "Private mode must admit the VPC CIDR only, on 80 and 443."
  }

  assert {
    condition     = aws_ecs_service.litellm.deployment_circuit_breaker[0].enable && aws_ecs_service.litellm.deployment_circuit_breaker[0].rollback
    error_message = "The deployment circuit breaker with rollback must be on."
  }

  assert {
    condition     = contains(tolist(aws_ecs_service.litellm.network_configuration[0].security_groups), var.data_ingress_security_group_id)
    error_message = "Service tasks must join the foundation's data-ingress security group."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].image == "ghcr.io/berriai/litellm:v1.106.6@sha256:37e2dafb088a7723beb998590682957386dfc83ffea1848486f8e0e5cfac0b06"
    error_message = "The service must run the official upstream image pinned by tag AND digest."
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["DISABLE_SCHEMA_UPDATE"] == "true"
    error_message = "Service tasks must run DISABLE_SCHEMA_UPDATE=true."
  }

  assert {
    condition = alltrue([
      { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["LITELLM_LOG"] == "INFO",
      { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["JSON_LOGS"] == "True",
    ])
    error_message = "Safe logging defaults: INFO level, JSON logs."
  }

  assert {
    condition     = strcontains(join(" ", jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.command), "/health/liveliness")
    error_message = "The container must have a real health check against the liveliness path."
  }

  # The health check is the template, rendered with the liveliness URL and 90 %
  # of the 4096 MiB task, comment lines dropped, inside python3 -c "...".
  # tests/test_healthcheck.py renders it the same way and runs it.
  assert {
    condition = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.command == [
      "CMD-SHELL",
      "python3 -c \"${replace(templatefile("${path.module}/templates/healthcheck.py.tftpl", {
        liveliness_url = "http://localhost:4000/health/liveliness"
        threshold_mib  = 3686
      }), "/(?m)^[ ]*#.*\n/", "")}\" || exit 1",
    ]
    error_message = "The health check must be the rendered template: liveliness, then the task memory at 3686 MiB (90 % of 4096)."
  }

  assert {
    condition = alltrue([
      for line in split("\n", jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.command[1]) :
      !startswith(trimspace(line), "#")
    ]) && length(regexall("[`$\\\\]", trimprefix(trimsuffix(jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.command[1], "\" || exit 1"), "python3 -c \""))) == 0
    error_message = "The inline script must hold no comment lines, backticks, dollar signs or backslashes (it sits in a double-quoted shell string)."
  }

  assert {
    condition     = aws_ecs_task_definition.litellm.memory == "4096" && aws_ecs_service.litellm.deployment_maximum_percent == 200 && aws_ecs_service.litellm.deployment_minimum_healthy_percent == 100
    error_message = "4096 MiB tasks; a replacement must fit next to every running task (maximum 200 %, minimum healthy 100 %)."
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets : s.name], "LITELLM_LICENSE")
    error_message = "LITELLM_LICENSE must not be set without a licence secret."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets :
      s.name == "DATABASE_URL" && s.valueFrom == var.database_url_secret_arn
    ])
    error_message = "DATABASE_URL must come from the foundation's Secrets Manager ARN."
  }

  assert {
    condition     = contains(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].command, "--skip_server_startup")
    error_message = "The migration task must run --skip_server_startup."
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].environment : e.name => e.value }["DISABLE_SCHEMA_UPDATE"] == "false"
    error_message = "Only the one-off migration task may migrate the schema."
  }

  assert {
    condition     = !strcontains(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].name, "LiteLLMContainer") && !can(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].healthCheck)
    error_message = "The migration task is a one-off: no service health check."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task.policy, "bedrock:InvokeModel") && !strcontains(aws_iam_role_policy.task.policy, "\"bedrock:*\"") && !strcontains(aws_iam_role_policy.task.policy, "\"Action\":\"*\"")
    error_message = "Task role: Bedrock inference + guardrails only, never bedrock:*."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task.policy, "arn:aws:s3:::${var.config_bucket_name}/config-*.yaml") && !strcontains(aws_iam_role_policy.task.policy, "s3:GetObject\",\"s3:PutObject")
    error_message = "Task role: read-only on the config object, write-only on the request logs."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.execution.policy, "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/openai-AbCdEf") && !strcontains(aws_iam_role_policy.execution.policy, "api_key::")
    error_message = "Execution role secret grants must be on the secret ARN, stripped of the :json-key:: suffix."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "ecr:")
    error_message = "No ECR permissions by default: the upstream image is pulled from ghcr.io."
  }

  assert {
    condition     = strcontains(terraform_data.litellm_config.input.content, "10.0.0.0/16") && strcontains(terraform_data.litellm_config.input.content, "trusted_proxy_ranges")
    error_message = "The rendered config must trust the ALB hop via trusted_proxy_ranges = [vpc_cidr]."
  }

  assert {
    condition     = strcontains(terraform_data.litellm_config.input.content, "turn_off_message_logging")
    error_message = "Message logging must be off."
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["LITELLM_CONFIG_SHA"] == sha256(terraform_data.litellm_config.input.content)
    error_message = "The task definition must carry the config content hash, so a config change rolls tasks."
  }

  assert {
    condition     = aws_appautoscaling_target.litellm.min_capacity == 2 && aws_appautoscaling_target.litellm.max_capacity == 20
    error_message = "Auto scaling runs between 2 and 20 tasks."
  }

  assert {
    condition     = aws_cloudwatch_log_group.litellm.retention_in_days == 3653
    error_message = "Ten-year (3653-day) log retention by default."
  }

  assert {
    condition     = [for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"][0] == "enabled"
    error_message = "Container Insights must be enabled."
  }

  assert {
    condition     = length(aws_route53_record.alb_alias) == 0
    error_message = "No DNS record without a hosted zone."
  }
}

run "rendered_config_has_no_models_by_default" {
  command = apply

  assert {
    condition     = length(yamldecode(terraform_data.litellm_config.input.content).model_list) == 0
    error_message = "Without config_override_file the rendered config must carry no models (they are added in the LiteLLM UI)."
  }
}

run "config_override_models_and_settings_merged" {
  command = apply

  variables {
    config_override_file = "tests/fixtures/config-override.yaml"
  }

  assert {
    condition     = [for m in yamldecode(terraform_data.litellm_config.input.content).model_list : m.model_name] == ["override-model"]
    error_message = "config_override_file model_list entries must be the rendered model list."
  }

  assert {
    condition     = yamldecode(terraform_data.litellm_config.input.content).router_settings.num_retries == 7
    error_message = "config_override_file *_settings keys must override the base config."
  }

  assert {
    condition     = yamldecode(terraform_data.litellm_config.input.content).litellm_settings.turn_off_message_logging == true
    error_message = "Base settings not named in the override must survive the merge."
  }
}

run "public_mode_wiring" {
  command = apply

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
  }

  # Public mode without an identity provider: the plan warns (see the
  # public_mode_without_identity_provider runs below).
  expect_failures = [check.public_mode_without_identity_provider]

  assert {
    condition     = aws_lb.this.internal == false && toset(aws_lb.this.subnets) == toset(var.public_subnet_ids)
    error_message = "Public mode must create an internet-facing ALB in the public subnets."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 1 && length(aws_wafv2_web_acl_association.alb) == 1
    error_message = "Public mode must attach the WAF."
  }

  assert {
    condition = anytrue([
      for r in aws_wafv2_web_acl.this[0].rule : anytrue([
        for o in r.statement[0].managed_rule_group_statement[0].rule_action_override :
        o.name == "SizeRestrictions_BODY" && length(o.action_to_use[0].count) == 1
      ]) if r.name == "AWSManagedRulesCommonRuleSet"
    ])
    error_message = "The WAF body-size rule must stay count-only: LLM requests exceed its 8 KB limit."
  }

  assert {
    condition = alltrue([
      for name in ["SizeRestrictions_BODY", "CrossSiteScripting_BODY", "GenericLFI_BODY", "GenericRFI_BODY", "EC2MetaDataSSRF_BODY", "RestrictedExtensions_URIPATH", "RestrictedExtensions_QUERYARGUMENTS"] :
      anytrue([
        for r in aws_wafv2_web_acl.this[0].rule : anytrue([
          for o in r.statement[0].managed_rule_group_statement[0].rule_action_override :
          o.name == name && length(o.action_to_use[0].count) == 1
        ]) if r.name == "AWSManagedRulesCommonRuleSet"
      ])
    ])
    error_message = "The common rule set body and file-extension rules must be count-only: prompts routinely contain HTML/JS, paths and URLs."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.this[0].rule : alltrue([
        for o in r.statement[0].managed_rule_group_statement[0].rule_action_override :
        endswith(o.name, "_BODY") || startswith(o.name, "RestrictedExtensions_") || o.name == "NoUserAgent_HEADER"
      ]) if r.name == "AWSManagedRulesCommonRuleSet"
    ])
    error_message = "Only body, file-extension and the no-user-agent rules may be overridden; URI, query and header rules keep blocking."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.waf) == 1 && aws_cloudwatch_log_group.waf[0].name == "aws-waf-logs-llmgw" && aws_cloudwatch_log_group.waf[0].retention_in_days == 3653
    error_message = "WAF logs must go to a log group named aws-waf-logs-<deployment_name> (an AWS requirement) with the default retention."
  }

  assert {
    condition     = aws_wafv2_web_acl_logging_configuration.this[0].resource_arn == aws_wafv2_web_acl.this[0].arn && aws_wafv2_web_acl_logging_configuration.this[0].log_destination_configs == toset([aws_cloudwatch_log_group.waf[0].arn])
    error_message = "WAF logging must be enabled for the web ACL into its log group."
  }

  assert {
    condition     = toset([for f in aws_wafv2_web_acl_logging_configuration.this[0].redacted_fields : f.single_header[0].name]) == toset(["authorization", "x-litellm-api-key", "api-key", "cookie"])
    error_message = "WAF logs must redact the API-key headers and cookies."
  }

  assert {
    condition = one([
      for r in aws_wafv2_web_acl.this[0].rule : r.action[0].block[0].custom_response[0].response_code if r.name == "RateLimitPerIp"
    ]) == 429 && one([for r in aws_wafv2_web_acl.this[0].rule : r.statement[0].rate_based_statement[0].limit if r.name == "RateLimitPerIp"]) == 2000
    error_message = "The per-IP rate limit (2000 per 5 minutes) must answer 429 so SDKs back off."
  }

  assert {
    condition     = contains([for k, v in aws_vpc_security_group_ingress_rule.alb : v.cidr_ipv4], "0.0.0.0/0")
    error_message = "Public mode admits the internet; the WAF and LiteLLM auth gate it."
  }
}

run "public_mode_needs_public_subnets" {
  command = plan

  variables {
    public_mode = true
  }

  # Also public without an identity provider, so the plan warning fires too.
  expect_failures = [var.public_subnet_ids, check.public_mode_without_identity_provider]
}

run "oidc_applied_in_private_mode" {
  command = apply

  variables {
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "00000000-0000-0000-0000-000000000000"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }

  assert {
    condition     = length(aws_lb_listener_rule.ui_oidc) == 2
    error_message = "An identity provider must put the OIDC action in front of the UI in private mode too (the route set spans two rules of at most five patterns)."
  }

  # The full set of UI and interactive sign-in routes of the pinned LiteLLM release.
  assert {
    condition = toset(flatten([for r in aws_lb_listener_rule.ui_oidc : [for c in r.condition : tolist(tolist(c.path_pattern)[0].values)]])) == toset([
      "/ui", "/ui/*", "/sso/*", "/login*", "/v2/login",
      "/v3/login*", "/fallback/login", "/onboarding/*", "/.well-known/litellm-ui-config", "/litellm/.well-known/litellm-ui-config",
    ])
    error_message = "The OIDC rules must cover exactly the UI, SSO, all login versions, the fallback login, onboarding and the UI discovery routes."
  }

  assert {
    condition     = alltrue([for r in aws_lb_listener_rule.ui_oidc : [for a in r.action : a.type][0] == "authenticate-oidc" && length([for c in r.condition : 1]) == 1 && length(tolist(tolist(r.condition)[0].path_pattern)[0].values) <= 5])
    error_message = "Every OIDC rule must authenticate first and stay within the ALB's five-pattern limit."
  }

  assert {
    condition = !anytrue([for p in flatten([for r in aws_lb_listener_rule.ui_oidc : [for c in r.condition : tolist(tolist(c.path_pattern)[0].values)]]) :
    anytrue([for api in ["/v1", "/chat", "/key", "/health", "/model"] : startswith(p, api)])])
    error_message = "API routes stay on LiteLLM key authentication; the OIDC rules must not cover them."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.alb_to_idp) == 1 && aws_vpc_security_group_egress_rule.alb_to_idp[0].from_port == 443 && aws_vpc_security_group_egress_rule.alb_to_idp[0].to_port == 443 && aws_vpc_security_group_egress_rule.alb_to_idp[0].ip_protocol == "tcp"
    error_message = "With an identity provider the ALB must be able to reach the IdP on tcp/443."
  }

  assert {
    condition     = anytrue([for c in aws_lb_listener_rule.ui_oidc[0].condition : contains(tolist(tolist(c.path_pattern)[0].values), "/ui/*")]) && [for a in aws_lb_listener_rule.ui_oidc[0].action : a.type][0] == "authenticate-oidc"
    error_message = "The OIDC action must cover the UI/sign-in paths only; API paths stay on LiteLLM auth."
  }
}

run "oidc_applied_in_public_mode" {
  command = apply

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "00000000-0000-0000-0000-000000000000"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }

  assert {
    condition     = length(aws_lb_listener_rule.ui_oidc) == 2
    error_message = "The OIDC action applies unconditionally in both modes."
  }
}

run "insecure_http_trial_wiring" {
  command = apply

  variables {
    certificate_arn     = null
    allow_insecure_http = true
  }

  assert {
    condition     = length(aws_lb_listener.https) == 0 && [for a in aws_lb_listener.http.default_action : a.type][0] == "forward"
    error_message = "The HTTP-only trial forwards port 80 straight to LiteLLM, with no HTTPS listener."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb) == 1 && values(aws_vpc_security_group_ingress_rule.alb)[0].from_port == 80
    error_message = "The HTTP-only trial must open port 80 only."
  }

  assert {
    condition     = startswith(output.service_url, "http://")
    error_message = "The trial's service URL is plain http://."
  }
}

run "client_cidrs_replace_vpc_default" {
  command = apply

  variables {
    client_cidrs = ["10.20.0.0/16", "192.168.10.0/24"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb) == 4 && !contains([for k, v in aws_vpc_security_group_ingress_rule.alb : v.cidr_ipv4], "10.0.0.0/16")
    error_message = "Listed client CIDRs must replace (not extend) the VPC-CIDR default."
  }
}

run "licence_and_ui_password_wired" {
  command = apply

  variables {
    litellm_license_secret_arn = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/licence-AbCdEf"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets :
      s.name == "LITELLM_LICENSE" && s.valueFrom == var.litellm_license_secret_arn
    ])
    error_message = "LITELLM_LICENSE must be wired exactly when the licence secret is given."
  }

  # The foundation always generates the UI password, so it is wired like the
  # other foundation secrets — never the master-key fallback.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets :
      s.name == "UI_PASSWORD" && s.valueFrom == var.ui_password_secret_arn
    ])
    error_message = "The foundation's UI password secret must reach the container as UI_PASSWORD."
  }

  assert {
    condition     = contains(one([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st.Resource if st.Sid == "Secrets"]), var.ui_password_secret_arn)
    error_message = "The execution role must be able to read the UI password secret."
  }
}

run "route53_alias_wiring" {
  command = apply

  variables {
    hosted_zone_id = "Z0123456789ABCDEFGHIJ"
    record_name    = "llm.example.com"
  }

  assert {
    condition     = length(aws_route53_record.alb_alias) == 1 && aws_route53_record.alb_alias[0].name == "llm.example.com"
    error_message = "hosted_zone_id + record_name must create the alias record."
  }

  assert {
    condition     = output.service_url == "https://llm.example.com"
    error_message = "The service URL must prefer the alias record."
  }
}

run "bedrock_allowlists_narrow_iam" {
  command = apply

  variables {
    bedrock_model_allowlist  = ["anthropic.claude-sonnet-4-5-20250929-v1:0"]
    bedrock_region_allowlist = ["eu-west-1"]
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task.policy, "arn:aws:bedrock:eu-west-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0") && !strcontains(aws_iam_role_policy.task.policy, "foundation-model/*")
    error_message = "Model and region allowlists must narrow the Bedrock resources."
  }
}

run "cross_account_wildcard_rejected" {
  command = plan

  variables {
    cross_account_role_arns = ["arn:aws:iam::222222222222:role/*"]
  }

  expect_failures = [var.cross_account_role_arns]
}

run "debug_log_level_warns" {
  command = apply

  variables {
    log_level = "DEBUG"
  }

  # The check block emits a warning (not an error): the apply must still succeed.
  expect_failures = [check.debug_logging_is_temporary]

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["LITELLM_LOG"] == "DEBUG"
    error_message = "DEBUG is allowed temporarily; the plan warning is the guard."
  }
}

run "no_sg_ingress_without_vpn_or_client_groups" {
  command = apply

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_from_sg) == 0
    error_message = "No security-group ingress on the ALB unless a VPN or client groups are given."
  }
}

run "foundation_vpn_security_group_admitted_to_alb" {
  command = apply

  variables {
    vpn_security_group_id     = "sg-0aaaaaaaaaaaaaaa1"
    client_security_group_ids = ["sg-0bbbbbbbbbbbbbbb2"]
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_sg["sg-0aaaaaaaaaaaaaaa1"].referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_ingress_rule.alb_from_sg["sg-0aaaaaaaaaaaaaaa1"].from_port == 443
    error_message = "The foundation's VPN security group must reach the ALB's HTTPS listener."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_from_sg) == 2
    error_message = "The VPN security group must add to (not replace) client_security_group_ids."
  }
}

run "ecr_image_uri_grants_repository_scoped_pull" {
  command = apply

  variables {
    image_uri = "222222222222.dkr.ecr.eu-central-1.amazonaws.com/platform/litellm@sha256:0a4015cbc1a045639e0f757404d39d527fed57efbff9305239178867dea043bf"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].image == var.image_uri
    error_message = "image_uri must replace the upstream image in the task definition."
  }

  assert {
    condition = one([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st if st.Sid == "EcrPull"]) == {
      Sid      = "EcrPull"
      Effect   = "Allow"
      Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Resource = "arn:aws:ecr:eu-central-1:222222222222:repository/platform/litellm"
    }
    error_message = "An ECR image_uri must grant image pulls on exactly that repository (account, region and name from the URI)."
  }

  assert {
    condition = one([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st if st.Sid == "EcrAuthToken"]) == {
      Sid      = "EcrAuthToken"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    }
    error_message = "An ECR image_uri must grant ecr:GetAuthorizationToken (Resource \"*\" is the only form AWS accepts)."
  }

  assert {
    condition     = sort([for a in flatten([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st.Action]) : a if startswith(a, "ecr:")]) == sort(["ecr:BatchGetImage", "ecr:GetAuthorizationToken", "ecr:GetDownloadUrlForLayer"])
    error_message = "An ECR image_uri must add exactly the three ECR pull actions, nothing broader."
  }
}

run "ecr_image_uri_with_tag_scopes_the_repository" {
  command = apply

  variables {
    image_uri = "222222222222.dkr.ecr.eu-central-1.amazonaws.com/litellm:v1.106.6"
  }

  assert {
    condition     = one([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st.Resource if st.Sid == "EcrPull"]) == "arn:aws:ecr:eu-central-1:222222222222:repository/litellm"
    error_message = "The tag must not leak into the repository ARN."
  }
}

run "default_image_has_no_ecr_statements" {
  command = apply

  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "ecr:") && length([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st if startswith(st.Sid, "Ecr")]) == 0
    error_message = "Without image_uri the execution role must carry no ECR statements."
  }
}

run "non_ecr_registry_has_no_ecr_statements" {
  command = apply

  variables {
    image_uri = "registry.example.com/platform/litellm@sha256:0a4015cbc1a045639e0f757404d39d527fed57efbff9305239178867dea043bf"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].image == var.image_uri
    error_message = "A custom registry image_uri must still replace the upstream image."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "ecr:")
    error_message = "A non-ECR registry must not add ECR permissions."
  }
}

run "ecr_lookalike_host_has_no_ecr_statements" {
  command = apply

  variables {
    image_uri = "222222222222.dkr.ecr.eu-central-1.amazonaws.com.evil.example/litellm:v1.106.6"
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "ecr:")
    error_message = "Only a genuine <account>.dkr.ecr.<region>.amazonaws.com host may add ECR permissions."
  }
}

# Public mode without an identity provider warns at plan time; the other three
# combinations stay silent (a failing check fails a run that does not expect it).

run "private_without_identity_provider_is_silent" {
  command = plan

  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.this) == 0 && length(aws_cloudwatch_log_group.waf) == 0
    error_message = "Private mode has no WAF and therefore no WAF logging."
  }
}

run "private_with_identity_provider_is_silent" {
  command = plan

  variables {
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "client"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }
}

run "public_with_identity_provider_is_silent" {
  command = plan

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "client"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }
}

run "public_without_identity_provider_warns" {
  command = plan

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
  }

  expect_failures = [check.public_mode_without_identity_provider]
}

run "response_cache_on_by_default" {
  command = apply

  assert {
    condition     = yamldecode(terraform_data.litellm_config.input.content).litellm_settings.cache == true && yamldecode(terraform_data.litellm_config.input.content).litellm_settings.cache_params.type == "redis"
    error_message = "The rendered config keeps LiteLLM's Redis response cache on by default."
  }
}

run "response_cache_disabled_through_override" {
  command = apply

  variables {
    config_override_file = "tests/fixtures/cache-off.yaml"
  }

  assert {
    condition     = yamldecode(terraform_data.litellm_config.input.content).litellm_settings.cache == false && yamldecode(terraform_data.litellm_config.input.content).litellm_settings.turn_off_message_logging == true
    error_message = "config_override_file must be able to switch the shared response cache off without dropping the other litellm_settings."
  }
}

run "log_buckets_keep_ten_years_by_default" {
  command = apply

  assert {
    condition = alltrue([
      for c in [aws_s3_bucket_lifecycle_configuration.access_logs, aws_s3_bucket_lifecycle_configuration.request_logs] :
      c.rule[0].expiration[0].days == 3653
    ])
    error_message = "The ALB access-log and request-log buckets must expire objects after the ten-year default."
  }
}

run "every_app_log_keeps_ten_years" {
  command = apply

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
  }

  expect_failures = [check.public_mode_without_identity_provider]

  assert {
    condition = (
      aws_cloudwatch_log_group.litellm.retention_in_days == 3653 &&
      aws_cloudwatch_log_group.waf[0].retention_in_days == 3653 &&
      aws_s3_bucket_lifecycle_configuration.access_logs.rule[0].expiration[0].days == 3653 &&
      aws_s3_bucket_lifecycle_configuration.request_logs.rule[0].expiration[0].days == 3653
    )
    error_message = "The LiteLLM and WAF log groups and both log buckets keep ten years (3653 days)."
  }
}

run "log_groups_survive_destroy_while_protected" {
  command = apply

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
  }

  expect_failures = [check.public_mode_without_identity_provider]

  assert {
    condition     = aws_cloudwatch_log_group.litellm.skip_destroy && aws_cloudwatch_log_group.waf[0].skip_destroy
    error_message = "With deletion_protection on (the default), destroy must keep the LiteLLM and WAF log groups."
  }
}

run "log_groups_are_destroyable_when_protection_is_off" {
  command = apply

  variables {
    public_mode         = true
    public_subnet_ids   = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
    deletion_protection = false
  }

  expect_failures = [check.public_mode_without_identity_provider]

  assert {
    condition     = !aws_cloudwatch_log_group.litellm.skip_destroy && !aws_cloudwatch_log_group.waf[0].skip_destroy
    error_message = "deletion_protection = false must let destroy remove the LiteLLM and WAF log groups."
  }
}

run "litellm_logs_mask_email_addresses" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_data_protection_policy.litellm.log_group_name == aws_cloudwatch_log_group.litellm.name
    error_message = "The data-protection policy must be attached to the LiteLLM log group."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_cloudwatch_log_data_protection_policy.litellm.policy_document).Statement : keys(s.Operation)[0]] == ["Audit", "Deidentify"] &&
      alltrue([for s in jsondecode(aws_cloudwatch_log_data_protection_policy.litellm.policy_document).Statement : s.DataIdentifier == ["arn:aws:dataprotection::aws:data-identifier/EmailAddress"]])
    )
    error_message = "The policy must audit and mask email addresses (one Audit and one Deidentify statement, as CloudWatch requires)."
  }
}

run "no_alb_egress_to_the_internet_without_identity_provider" {
  command = apply

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.alb_to_idp) == 0
    error_message = "Without an identity provider the ALB has no internet egress."
  }
}

run "identity_provider_without_outbound_access_warns" {
  command = plan

  variables {
    disable_outbound_network_access = true
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "client"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }

  expect_failures = [check.identity_provider_needs_outbound_access]
}

run "override_passes_unknown_top_level_keys_through" {
  command = apply

  variables {
    config_override_file = "tests/fixtures/guardrails.yaml"
  }

  assert {
    condition     = yamldecode(terraform_data.litellm_config.input.content).guardrails[0].guardrail_name == "bedrock-guard"
    error_message = "Top-level override keys such as guardrails must reach the rendered config."
  }

  assert {
    condition = (
      yamldecode(terraform_data.litellm_config.input.content).general_settings.master_key_header_name == "x-api-key" &&
      yamldecode(terraform_data.litellm_config.input.content).general_settings.proxy_batch_write_at == 60 &&
      length(yamldecode(terraform_data.litellm_config.input.content).general_settings.trusted_proxy_ranges) == 1
    )
    error_message = "general_settings from the override must merge key-by-key over the base, not replace it."
  }
}

run "config_object_is_content_addressed" {
  command = apply

  assert {
    condition     = terraform_data.litellm_config.input.key == "config-${substr(sha256(terraform_data.litellm_config.input.content), 0, 16)}.yaml"
    error_message = "The config object key must carry the content hash."
  }

  assert {
    condition = anytrue([
      for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment :
      e.name == "LITELLM_CONFIG_BUCKET_OBJECT_KEY" && e.value == terraform_data.litellm_config.input.key
    ])
    error_message = "The task definition must name the content-addressed config key, so each revision loads its own config."
  }

  assert {
    condition     = one([for st in jsondecode(aws_iam_role_policy.task.policy).Statement : st.Resource if st.Sid == "ReadConfig"]) == "arn:aws:s3:::${var.config_bucket_name}/config-*.yaml"
    error_message = "The task role may read the config objects only."
  }
}

run "alb_logs_use_the_log_delivery_service_principal" {
  command = apply

  assert {
    condition = one([for st in jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement : st if st.Sid == "AllowELBLogDelivery"]) == {
      Sid       = "AllowELBLogDelivery"
      Effect    = "Allow"
      Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:elasticloadbalancing:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:loadbalancer/app/llmgw-alb/*" }
      }
    }
    error_message = "ALB log delivery must use the service principal, scoped to this account's load balancer."
  }
}

run "task_role_trust_is_scoped_to_this_account" {
  command = apply

  assert {
    condition = alltrue([
      for r in [aws_iam_role.task, aws_iam_role.execution] :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == data.aws_caller_identity.current.account_id &&
      jsondecode(r.assume_role_policy).Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
    ])
    error_message = "Both ecs-tasks trust policies need the aws:SourceAccount and aws:SourceArn confused-deputy conditions."
  }
}

run "reserved_name_in_extra_environment_rejected" {
  command = plan

  variables {
    extra_environment = { DISABLE_SCHEMA_UPDATE = "false" }
  }

  expect_failures = [var.extra_environment]
}

run "debug_log_level_through_extra_environment_rejected" {
  command = plan

  variables {
    extra_environment = { LITELLM_LOG = "DEBUG" }
  }

  expect_failures = [var.extra_environment]
}

run "reserved_prefix_in_extra_environment_rejected" {
  command = plan

  variables {
    extra_environment = { REDIS_HOST = "elsewhere" }
  }

  expect_failures = [var.extra_environment]
}

run "reserved_name_in_provider_secret_arns_rejected" {
  command = plan

  variables {
    provider_secret_arns = { LITELLM_MASTER_KEY = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:other-AbCdEf" }
  }

  expect_failures = [var.provider_secret_arns]
}

run "name_in_both_maps_rejected" {
  command = plan

  variables {
    extra_environment    = { OPENAI_API_KEY = "plain" }
    provider_secret_arns = { OPENAI_API_KEY = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/openai-AbCdEf" }
  }

  expect_failures = [var.provider_secret_arns]
}

run "image_uri_override_still_replaces_the_pinned_image" {
  command = apply

  variables {
    image_uri = "registry.example.com/litellm@sha256:0a4015cbc1a045639e0f757404d39d527fed57efbff9305239178867dea043bf"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].image == var.image_uri
    error_message = "image_uri must replace the pinned upstream image."
  }
}

run "db_unavailable_override_warns" {
  command = plan

  variables {
    config_override_file = "tests/fixtures/allow-db-unavailable.yaml"
  }

  expect_failures = [check.db_unavailable_requests_not_allowed]
}

run "request_count_restarts_rejected" {
  command = plan

  variables {
    extra_environment = { MAX_REQUESTS_BEFORE_RESTART = "50000" }
  }

  expect_failures = [var.extra_environment]
}

# Regions launched before August 2022 deliver ALB access logs from the region's
# ELB account; later regions only through the log-delivery service principal.

run "legacy_region_grants_the_region_elb_account" {
  command = apply

  override_data {
    target = data.aws_region.current
    values = { region = "ap-southeast-2" }
  }

  assert {
    condition = one([for st in jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement : st if st.Sid == "AllowLegacyRegionELBLogDelivery"]) == {
      Sid       = "AllowLegacyRegionELBLogDelivery"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::783225319266:root" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    }
    error_message = "In ap-southeast-2 the policy must also grant the region's ELB account (783225319266)."
  }

  assert {
    condition     = one([for st in jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement : st.Principal.Service if st.Sid == "AllowELBLogDelivery"]) == "logdelivery.elasticloadbalancing.amazonaws.com"
    error_message = "The log-delivery service principal statement must be present in legacy regions too."
  }
}

run "us_east_1_grants_its_elb_account" {
  command = apply

  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  assert {
    condition     = one([for st in jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement : st.Principal.AWS if st.Sid == "AllowLegacyRegionELBLogDelivery"]) == "arn:aws:iam::127311923021:root"
    error_message = "In us-east-1 the policy must grant the region's ELB account (127311923021)."
  }
}

run "post_2022_region_uses_the_service_principal_only" {
  command = apply

  override_data {
    target = data.aws_region.current
    values = { region = "eu-central-2" }
  }

  assert {
    condition     = length([for st in jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement : st if st.Sid == "AllowLegacyRegionELBLogDelivery"]) == 0
    error_message = "eu-central-2 has no ELB account: the policy must not carry the legacy statement."
  }

  assert {
    condition     = one([for st in jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement : st.Principal.Service if st.Sid == "AllowELBLogDelivery"]) == "logdelivery.elasticloadbalancing.amazonaws.com"
    error_message = "The log-delivery service principal statement must be present in post-2022 regions."
  }

  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.access_logs.policy).Statement) == 2
    error_message = "A post-2022 region's policy holds exactly the TLS-only deny and the service-principal grant."
  }
}
