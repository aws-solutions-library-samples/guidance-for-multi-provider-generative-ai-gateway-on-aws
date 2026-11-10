# Service roles for the foundation's own infrastructure. Scoped to the named
# resources — no managed full-access policies except AWS's own
# service-role policy for RDS Enhanced Monitoring.

resource "aws_iam_role" "vpc_flow_logs" {
  count = local.creating_new_vpc ? 1 : 0
  name  = "${var.deployment_name}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

# Scoped to the flow log group, not CloudWatchLogsFullAccess.
resource "aws_iam_role_policy" "vpc_flow_logs" {
  count = local.creating_new_vpc ? 1 : 0
  name  = "${var.deployment_name}-vpc-flow-logs"
  role  = aws_iam_role.vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs[0].arn}:*"
    }]
  })
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${var.deployment_name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
