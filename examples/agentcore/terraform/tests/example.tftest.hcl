# Plans the example against a mocked AWS provider: the runtime's network,
# configuration and permissions, the key's lifecycle wiring and the input
# validations. Nothing touches AWS or the gateway (plans run no provisioners).
#
#   terraform -chdir=examples/agentcore/terraform init -backend=false
#   terraform -chdir=examples/agentcore/terraform test

mock_provider "aws" {
  override_during = plan # computed mock values (ARNs) are known while planning

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }

  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/llmgw-agent-demo-runtime" }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw-agent-demo-gateway-key-AbCdEf" }
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::llmgw-agent-demo-code-111111111111-eu-west-1" }
  }

  mock_resource "aws_bedrockagentcore_api_key_credential_provider" {
    defaults = { credential_provider_arn = "arn:aws:bedrock-agentcore:eu-west-1:111111111111:token-vault/default/apikeycredentialprovider/llmgw-agent-demo-gateway" }
  }
}

variables {
  gateway_url           = "http://internal-gw.eu-west-1.elb.amazonaws.com"
  master_key_secret_arn = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw-master-key-abc"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_ids            = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
  gateway_cidr          = "10.0.0.0/16"
  model_id              = "claude-opus-5-5"
  code_zip_path         = "tests/fixtures/agent-bundle.txt"
}

run "runtime_reaches_the_gateway_from_the_vpc" {
  command = plan

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_name == "llmgw_agent_demo"
    error_message = "The runtime name is the agent name with underscores."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.agent.network_configuration[0].network_mode == "VPC"
    error_message = "The runtime must run in the gateway's VPC."
  }

  assert {
    condition     = toset(aws_bedrockagentcore_agent_runtime.agent.network_configuration[0].network_mode_config[0].subnets) == toset(var.subnet_ids)
    error_message = "The runtime must use the given subnets."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.gateway.cidr_ipv4 == "10.0.0.0/16" &&
      aws_vpc_security_group_egress_rule.gateway.from_port == 80 &&
      aws_vpc_security_group_egress_rule.gateway.to_port == 80
    )
    error_message = "Egress to the gateway must be its CIDR on the URL's port (80 for http)."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.aws_apis.from_port == 443 && aws_vpc_security_group_egress_rule.aws_apis.to_port == 443
    error_message = "Egress to AWS APIs must be HTTPS only."
  }
}

run "agent_is_configured_for_the_gateway_without_the_key" {
  command = plan

  assert {
    condition = tomap(aws_bedrockagentcore_agent_runtime.agent.environment_variables) == tomap({
      GATEWAY_BASE_URL    = "http://internal-gw.eu-west-1.elb.amazonaws.com"
      MODEL_ID            = "claude-opus-5-5"
      CREDENTIAL_PROVIDER = "llmgw-agent-demo-gateway"
      MAX_TOKENS          = "1024"
    })
    error_message = "The runtime gets the gateway URL, model and credential provider name, and no key."
  }

  assert {
    condition = (
      aws_bedrockagentcore_api_key_credential_provider.gateway.api_key_secret_source == "EXTERNAL" &&
      aws_bedrockagentcore_api_key_credential_provider.gateway.api_key_secret_config[0].json_key == "api_key" &&
      aws_bedrockagentcore_api_key_credential_provider.gateway.api_key == null
    )
    error_message = "The credential provider must read the key from the example's secret, never from state."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_artifact[0].code_configuration[0].runtime == "PYTHON_3_13"
    error_message = "The bundle is built for CPython 3.13."
  }

  assert {
    condition     = startswith(aws_s3_object.code.key, "agent/") && endswith(aws_s3_object.code.key, ".zip")
    error_message = "The code bundle key is content-addressed under agent/."
  }
}

run "key_request_limits_the_agent" {
  command = plan

  variables {
    key_max_budget = 2
    key_rpm_limit  = 10
  }

  assert {
    condition = jsondecode(terraform_data.gateway_key.input.key_request) == {
      key_alias       = "llmgw-agent-demo"
      models          = ["claude-opus-5-5"]
      max_budget      = 2
      budget_duration = "30d"
      rpm_limit       = 10
      tpm_limit       = 100000
      metadata = {
        agentcore_runtime_name = "llmgw_agent_demo"
        created_by             = "examples/agentcore"
      }
    }
    error_message = "The virtual key is limited to the agent's model, budget and rate limits."
  }
}

# The policy document's JSON is mocked, so its statements are checked as written.
run "runtime_role_has_no_direct_model_access" {
  command = plan

  assert {
    condition = !anytrue(flatten([
      for st in data.aws_iam_policy_document.runtime.statement : [for a in st.actions : startswith(a, "bedrock:")]
    ]))
    error_message = "The runtime role must not be able to call Amazon Bedrock directly."
  }

  assert {
    condition = anytrue([
      for st in data.aws_iam_policy_document.runtime.statement : contains(tolist(st.actions), "bedrock-agentcore:GetResourceApiKey")
    ])
    error_message = "The runtime role must be able to fetch the gateway key from AgentCore Identity."
  }

  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.runtime.statement :
      toset(st.resources) == toset(["arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw-agent-demo-gateway-key-AbCdEf"])
      if contains(tolist(st.actions), "secretsmanager:GetSecretValue")
    ])
    error_message = "Secret access must be limited to the agent's key secret (never the master key)."
  }
}

run "https_gateway_with_explicit_port" {
  command = plan

  variables {
    gateway_url = "https://llm.example.com:8443"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.gateway.from_port == 8443
    error_message = "An explicit port in the gateway URL wins."
  }
}

run "rejects_gateway_url_with_path" {
  command = plan

  variables {
    gateway_url = "https://llm.example.com/v1"
  }

  expect_failures = [var.gateway_url]
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "Agent_1"
  }

  expect_failures = [var.name]
}
