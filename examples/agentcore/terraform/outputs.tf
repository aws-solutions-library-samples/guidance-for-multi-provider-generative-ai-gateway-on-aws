# Read by scripts/agent-key.sh and scripts/invoke.py.
# Identifiers only: no secret values.

output "agent_runtime_arn" {
  description = "ARN of the AgentCore runtime (invoke it with bedrock-agentcore InvokeAgentRuntime)."
  value       = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_arn
}

output "agent_runtime_id" {
  description = "ID of the AgentCore runtime; its logs are in /aws/bedrock-agentcore/runtimes/<id>-DEFAULT."
  value       = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_id
}

output "execution_role_arn" {
  description = "The runtime's execution role."
  value       = aws_iam_role.runtime.arn
}

output "credential_provider_arn" {
  description = "AgentCore Identity API-key credential provider holding the gateway key."
  value       = aws_bedrockagentcore_api_key_credential_provider.gateway.credential_provider_arn
}

output "gateway_key_secret_arn" {
  description = "Secrets Manager secret holding the agent's virtual key."
  value       = aws_secretsmanager_secret.gateway_key.arn
}

output "security_group_id" {
  description = "Security group of the runtime's network interfaces."
  value       = aws_security_group.runtime.id
}

output "code_bucket" {
  description = "Bucket holding the agent's code bundles."
  value       = aws_s3_bucket.code.bucket
}

# Inputs of scripts/agent-key.sh rotate|status.
output "gateway_key_settings" {
  description = "Where and how the agent's LiteLLM virtual key is managed (no secret values)."
  value = {
    gateway_url           = var.gateway_url
    master_key_secret_arn = var.master_key_secret_arn
    key_secret_arn        = aws_secretsmanager_secret.gateway_key.arn
    key_request           = local.key_request
    ca_file               = local.gateway_ca_file
  }
}
