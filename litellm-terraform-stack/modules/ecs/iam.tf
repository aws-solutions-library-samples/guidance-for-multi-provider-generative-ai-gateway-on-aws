data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_role" {
  name               = "${var.name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "ecs_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution_role" {
  name               = "${var.name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_execution_assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_role_attachment" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_role_policy_doc" {
  statement {
    sid       = "EcrImageAccess"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [
      "*"
    ]
  }

  statement {
    sid       = "EcrTokenAccess"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = [
      "*"
    ]
  }

  statement {
    sid       = "CloudwatchAccess"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.master_and_salt_key_secret_arn, var.main_db_secret_arn, var.middleware_db_secret_arn, aws_secretsmanager_secret.litellm_other_secrets.arn]
  }
}

resource "aws_iam_policy" "execution_role_policy" {
  name   = "${var.name}-ecs-execution-role-policy"
  policy = data.aws_iam_policy_document.execution_role_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "execution_role_attach" {
  role       = aws_iam_role.execution_role.name
  policy_arn = aws_iam_policy.execution_role_policy.arn
}

# --------------------------------------------------------------------
# Task Role Policy (S3, Bedrock, SageMaker)
# --------------------------------------------------------------------
data "aws_iam_policy_document" "task_role_policy_doc" {
  statement {
    sid       = "S3ConfigBucketAccess"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      var.config_bucket_arn,
      "${var.config_bucket_arn}/*"
    ]
  }

  statement {
    sid       = "S3LogBucketAccess"
    actions   = ["s3:*"]
    resources = [
      var.log_bucket_arn,
      "${var.log_bucket_arn}/*"
    ]
  }

  statement {
    sid       = "BedrockAccess"
    actions   = ["bedrock:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SageMakerInvoke"
    actions   = ["sagemaker:InvokeEndpoint"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "task_role_policy" {
  name   = "${var.name}-ecs-task-role-policy"
  policy = data.aws_iam_policy_document.task_role_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "task_role_attach" {
  role       = aws_iam_role.task_role.name
  policy_arn = aws_iam_policy.task_role_policy.arn
}