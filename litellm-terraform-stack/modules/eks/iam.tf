resource "aws_iam_role" "eks_developers" {
  name               = "${var.name}-developers"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role" "eks_operators" {
  name               = "${var.name}-operators"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "eks_nodegroup" {
  name = "${var.name}-eks-nodegroup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach AWS-managed policies
resource "aws_iam_role_policy_attachment" "eks_nodegroup_worker_policy" {
  role       = aws_iam_role.eks_nodegroup.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_nodegroup_cni_policy" {
  role       = aws_iam_role.eks_nodegroup.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_nodegroup_ec2_registry" {
  role       = aws_iam_role.eks_nodegroup.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_nodegroup_ssm" {
  role       = aws_iam_role.eks_nodegroup.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "nodegroup_ecr_ptc" {
  statement {
    sid     = "ECRPullThroughCache"
    effect  = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "nodegroup_ecr_ptc" {
  name        = "${var.name}-nodegroup-ecr-ptc"
  policy      = data.aws_iam_policy_document.nodegroup_ecr_ptc.json
  description = "Allow ECR Pull Through Cache"
}

resource "aws_iam_policy_attachment" "nodegroup_ecr_ptc_attach" {
  name       = "${var.name}-nodegroup-ecr-ptc-attach"
  policy_arn = aws_iam_policy.nodegroup_ecr_ptc.arn
  roles      = [aws_iam_role.eks_nodegroup.name]
}

# Additional custom inline policy for the node group
resource "aws_iam_role_policy" "node_additional_policies" {
  name = "${var.name}-eks-node-additional"
  role = aws_iam_role.eks_nodegroup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.config_bucket_arn,
          "${var.config_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = [
          var.log_bucket_arn,
          "${var.log_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:*"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = ["*"]
      }
    ]
  })
}