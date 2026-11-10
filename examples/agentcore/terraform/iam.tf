# Execution role of the AgentCore runtime. It can write the runtime's logs,
# traces and metrics, read the code bundle, and obtain the agent's gateway key
# through AgentCore Identity. It has no Amazon Bedrock permissions: the agent
# reaches models through the gateway only.

data "aws_iam_policy_document" "runtime_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.name}-runtime"
  description        = "AgentCore Runtime execution role of ${var.name} (no direct model access)"
  assume_role_policy = data.aws_iam_policy_document.runtime_trust.json
}

locals {
  identity_directory = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default"
  token_vault        = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default"
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid = "RuntimeLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
    ]
  }

  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
  }

  statement {
    sid = "Traces"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"] # X-Ray has no resource-level permissions for these actions
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData has no resource-level permissions; the namespace is pinned instead
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  statement {
    sid       = "ReadCodeBundle"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.code.arn}/agent/*"]
  }

  statement {
    sid = "WorkloadAccessToken"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
      "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
    ]
    resources = [
      local.identity_directory,
      "${local.identity_directory}/workload-identity/${local.runtime_name}-*",
    ]
  }

  statement {
    sid     = "GatewayKey"
    actions = ["bedrock-agentcore:GetResourceApiKey"]
    resources = [
      local.identity_directory,
      "${local.identity_directory}/workload-identity/${local.runtime_name}-*",
      local.token_vault,
      aws_bedrockagentcore_api_key_credential_provider.gateway.credential_provider_arn,
    ]
  }

  statement {
    sid       = "GatewayKeySecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.gateway_key.arn]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "runtime"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json
}
