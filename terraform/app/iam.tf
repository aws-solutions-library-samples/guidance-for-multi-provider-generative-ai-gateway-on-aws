# Least-privilege IAM. Policies are built with jsonencode (not the
# aws_iam_policy_document data source) so `terraform test` with mocked providers
# can assert on their exact content.
#
# Task role: Bedrock inference + guardrails only (optional model/region
# allowlists), write-only request-log bucket, read-only config object.
# Execution role: logs, the named secrets, the customer KMS key, and ECR pull
# rights only when image_uri points at a private ECR repository. The default
# upstream image comes from ghcr.io and needs no registry permissions. No `*`
# actions anywhere.

locals {
  # Confused-deputy guard: ECS may assume these roles only for tasks in this
  # account and region.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })

  # Secrets the execution role may read: strip the optional :json-key:: suffix
  # (name:key::) down to the secret ARN itself.
  all_secret_arns = distinct([
    for v in values(local.container.secrets) :
    regex("^(arn:[^:]+:secretsmanager:[^:]+:[^:]+:secret:[^:]+)", v)[0]
  ])

  # image_uri as <account>.dkr.ecr.<region>.amazonaws.com/<repository>[:tag][@digest];
  # any other registry (or the default ghcr.io image) yields no match.
  ecr_image = var.image_uri == null ? null : one(regexall(
    "^(?P<account>[0-9]{12})\\.dkr\\.ecr\\.(?P<region>[a-z0-9-]+)\\.amazonaws\\.com/(?P<repository>[a-z0-9][a-z0-9._/-]*?)(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(?:@sha256:[0-9a-f]{64})?$",
    var.image_uri,
  ))

  execution_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "Logs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.litellm.arn}:*"
        },
        {
          Sid      = "Secrets"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = local.all_secret_arns
        },
      ],
      var.kms_key_arn != null ? [{
        Sid      = "DecryptWithCustomerKey"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.kms_key_arn
      }] : [],
      local.ecr_image != null ? [
        {
          Sid      = "EcrPull"
          Effect   = "Allow"
          Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
          Resource = "arn:aws:ecr:${local.ecr_image.region}:${local.ecr_image.account}:repository/${local.ecr_image.repository}"
        },
        {
          Sid    = "EcrAuthToken"
          Effect = "Allow"
          Action = ["ecr:GetAuthorizationToken"]
          # GetAuthorizationToken does not support resource-level permissions; "*" is the only accepted Resource.
          Resource = "*"
        },
      ] : [],
    )
  })

  # Any model and inference profile in any region by default (cross-region
  # inference profiles and new regions work without a redeploy); the optional
  # allowlists narrow it.
  bedrock_regions = length(var.bedrock_region_allowlist) > 0 ? var.bedrock_region_allowlist : ["*"]
  bedrock_model_resources = length(var.bedrock_model_allowlist) > 0 ? flatten([
    for r in local.bedrock_regions : [
      for m in var.bedrock_model_allowlist : [
        "arn:aws:bedrock:${r}::foundation-model/${m}",
        "arn:aws:bedrock:${r}:${data.aws_caller_identity.current.account_id}:inference-profile/*${m}",
      ]
    ]
    ]) : flatten([for r in local.bedrock_regions : [
      "arn:aws:bedrock:${r}::foundation-model/*",
      "arn:aws:bedrock:${r}:*:inference-profile/*",
      "arn:aws:bedrock:${r}:*:application-inference-profile/*",
  ]])

  task_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadConfig"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "arn:aws:s3:::${var.config_bucket_name}/config-*.yaml"
        },
        {
          Sid      = "WriteRequestLogs"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.request_logs.arn}/*"
        },
        {
          Sid    = "BedrockInference"
          Effect = "Allow"
          Action = [
            "bedrock:InvokeModel",
            "bedrock:InvokeModelWithResponseStream",
            "bedrock:Converse",
            "bedrock:ConverseStream",
            "bedrock:CountTokens",
          ]
          Resource = local.bedrock_model_resources
        },
        {
          Sid      = "BedrockGuardrails"
          Effect   = "Allow"
          Action   = "bedrock:ApplyGuardrail"
          Resource = "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:guardrail/*"
        },
      ],
      # Cross-account roles are listed explicitly; wildcards are rejected in variables.tf.
      length(var.cross_account_role_arns) > 0 ? [{
        Sid      = "CrossAccountModels"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.cross_account_role_arns
      }] : [],
      var.kms_key_arn != null ? [{
        Sid      = "DecryptConfigAndEncryptLogs"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      }] : [],
    )
  })
}

resource "aws_iam_role" "task" {
  name               = "${var.deployment_name}-ecs-task-role"
  assume_role_policy = local.assume_role_policy
}

resource "aws_iam_role" "execution" {
  name               = "${var.deployment_name}-ecs-execution-role"
  assume_role_policy = local.assume_role_policy
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.deployment_name}-ecs-execution"
  role   = aws_iam_role.execution.id
  policy = local.execution_policy
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.deployment_name}-ecs-task"
  role   = aws_iam_role.task.id
  policy = local.task_policy
}
