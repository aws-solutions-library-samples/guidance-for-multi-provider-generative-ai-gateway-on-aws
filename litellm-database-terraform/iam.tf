# VPC Flow Logs to CloudWatch, replicating cdk FlowLog to logs with 1 minute interval
# In Terraform, we need an IAM role to publish flow logs to CloudWatch.
resource "aws_iam_role" "vpc_flow_logs_role" {
  count = (length(trimspace(var.vpc_id)) == 0) ? 1 : 0
  name               = "${var.stack_name}-vpc-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_logs_assume.json
}

data "aws_iam_policy_document" "vpc_flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "vpc_flow_logs_attach" {
  count      = (length(trimspace(var.vpc_id)) == 0) ? 1 : 0
  role       = aws_iam_role.vpc_flow_logs_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}
