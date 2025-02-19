data "aws_region" "current" {}

resource "aws_security_group" "vpc_endpoints_sg" {
  count             = local.create_endpoints ? 1 : 0
  name              = "${var.name}-vpc-endpoints-sg"
  description       = "Security group for Interface VPC Endpoints"
  vpc_id            = local.final_vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [cidrsubnet("0.0.0.0/0", 0, 0)] # or limit to local.final_vpc_id's CIDR if you prefer
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# For each endpoint the CDK creates, we'll have a corresponding resource:
# We'll do the S3 Gateway + the various Interface endpoints.
# We'll rely on local.create_endpoints so that we skip them if not needed.

# S3 Gateway
resource "aws_vpc_endpoint" "s3_gateway" {
  count             = local.create_endpoints ? 1 : 0
  vpc_id            = local.final_vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.s3_gateway_route_table_ids
}

# For each interface endpoint, we do "aws_vpc_endpoint" with type = "Interface" 
# + the security group above, + subnets = local.chosen_subnet_ids
# We'll define a local variable listing the services we want in EKS or ECS scenarios,
# since the CDK has conditionals for EKS. But we’ll just replicate the logic individually.

# Secrets Manager
resource "aws_vpc_endpoint" "secretsmanager" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

# ECR
resource "aws_vpc_endpoint" "ecr" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "ecr_docker" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

# CloudWatch Logs
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

# STS
resource "aws_vpc_endpoint" "sts" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

# Sagemaker runtime
resource "aws_vpc_endpoint" "sagemaker_runtime" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.sagemaker.runtime"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

# Bedrock
resource "aws_vpc_endpoint" "bedrock" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.bedrock"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.bedrock-runtime"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "bedrock_agent" {
  count                    = local.create_endpoints ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.bedrock-agent"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  //subnet_ids               = local.chosen_subnet_ids
  subnet_ids               = local.bedrock_agent_compatible_subnets
  private_dns_enabled      = true
}

# Additional endpoints if deploymentPlatform == EKS
#   EKS, EC2, EC2 messages, SSM, SSM messages, CloudWatch monitoring, ELB, ASG, WAFv2
resource "aws_vpc_endpoint" "eks" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.eks"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "ec2" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.ec2"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "ec2_messages" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "ssm" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "ssm_messages" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "cloudwatch_monitoring" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.monitoring"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "elb" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.elasticloadbalancing"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "autoscaling" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id                   = local.final_vpc_id
  service_name             = "com.amazonaws.${data.aws_region.current.name}.autoscaling"
  vpc_endpoint_type        = "Interface"
  security_group_ids       = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids               = local.chosen_subnet_ids
  private_dns_enabled      = true
}

resource "aws_vpc_endpoint" "wafv2" {
  count = local.create_endpoints && var.deployment_platform == "EKS" ? 1 : 0
  vpc_id              = local.final_vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.wafv2"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg[0].id]
  subnet_ids          = local.chosen_subnet_ids
  private_dns_enabled = true
}
