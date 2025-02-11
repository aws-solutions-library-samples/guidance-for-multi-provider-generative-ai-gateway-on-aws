################################################################################
# Cluster
################################################################################
# Data source for existing EKS cluster (when importing)

data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Tag public subnets for internet-facing ALB
resource "aws_ec2_tag" "public_subnet_elb" {
  # Use for_each to tag all public subnets
  for_each    = toset(data.aws_subnets.public.ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# Tag private subnets for internal ALB (optional but recommended)
resource "aws_ec2_tag" "private_subnet_internal_elb" {
  # Use for_each to tag all private subnets
  for_each    = toset(data.aws_subnets.private.ids)
  resource_id = each.value
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnets_cluster" {
  for_each    = toset(data.aws_subnets.private.ids)
  resource_id = each.value

  key   = "kubernetes.io/cluster/${local.cluster_name}"
  value = "shared"  # or "owned"
}

resource "aws_ec2_tag" "public_subnets_cluster" {
  for_each    = toset(data.aws_subnets.public.ids)
  resource_id = each.value

  key   = "kubernetes.io/cluster/${local.cluster_name}"
  value = "shared"  # or "owned"
}


# First, import the existing security groups
data "aws_security_group" "db" {
  id = var.db_security_group_id
}

data "aws_security_group" "redis" {
  id = var.redis_security_group_id
}

# Add ingress rules to DB security group
resource "aws_security_group_rule" "db_ingress" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.existing.cidr_block]
  security_group_id = data.aws_security_group.db.id
}

# Add ingress rules to Redis security group
resource "aws_security_group_rule" "redis_ingress" {
  type              = "ingress"
  from_port         = 6379
  to_port           = 6379
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.existing.cidr_block]
  security_group_id = data.aws_security_group.redis.id
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  count = var.create_cluster ? 1 : 0
  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}


resource "aws_iam_role" "eks_cluster" {
  count = var.create_cluster ? 1 : 0

  name = "${var.name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_eks_cluster" "this" {
  count = var.create_cluster ? 1 : 0

  name     = "${var.name}-cluster"
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster[0].arn

  vpc_config {
    subnet_ids              = concat(data.aws_subnets.private.ids, data.aws_subnets.public.ids)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # If your cluster IAM role or its policies are managed elsewhere,
  # you can add explicit depends_on to ensure they exist first:
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  # Example: pass tags to the cluster
  tags = local.tags
}

# Look up existing EKS cluster only if create_cluster = false
data "aws_eks_cluster" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.existing_cluster_name
}

data "aws_eks_cluster_auth" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.existing_cluster_name
}

locals {
  # If create_cluster is true, reference the newly-created EKS cluster;
  # otherwise reference the existing EKS cluster data source.
  cluster_name = var.create_cluster ? aws_eks_cluster.this[0].name : data.aws_eks_cluster.existing[0].name
  cluster_endpoint = var.create_cluster ? aws_eks_cluster.this[0].endpoint : data.aws_eks_cluster.existing[0].endpoint
  cluster_ca = var.create_cluster ? aws_eks_cluster.this[0].certificate_authority[0].data : data.aws_eks_cluster.existing[0].certificate_authority[0].data
  cluster_security_group_id = var.create_cluster ? aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id : data.aws_eks_cluster.existing[0].vpc_config[0].cluster_security_group_id
  cluster_tls_url = var.create_cluster ? aws_eks_cluster.this[0].identity[0].oidc[0].issuer : data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer
}


# OIDC provider for the cluster (to replace module.eks.oidc_provider_arn)
data "tls_certificate" "eks_oidc" {
  url = local.cluster_tls_url
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = local.cluster_tls_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  # Wait until the cluster and its endpoint are actually ready
  depends_on = [
    aws_eks_cluster.this, aws_iam_role.eks_nodegroup
  ]

  # The 'data' block is YAML that instructs EKS how to map IAM roles to Kubernetes RBAC
  data = {
    # Map IAM roles for the Node Group
    mapRoles = <<-YAML
      - rolearn: ${aws_iam_role.eks_nodegroup.arn}
        username: system:node:{{EC2PrivateDNSName}}
        groups:
          - system:bootstrappers
          - system:nodes
      - rolearn: ${aws_iam_role.eks_developers.arn}
        username: eks-developers
        groups:
          - eks-developers
      - rolearn: ${aws_iam_role.eks_operators.arn}
        username: eks-operators
        groups:
          - eks-operators
    YAML
  }
}

###############################################################################
# EKS Addons (replacing cluster_addons in the module)                         #
###############################################################################
resource "aws_eks_addon" "coredns" {
  cluster_name = local.cluster_name
  addon_name   = "coredns"

  # If we create the cluster, wait for it & the node group. Otherwise no wait.
  depends_on = [aws_eks_cluster.this, aws_eks_node_group.core_nodegroup]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = local.cluster_name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = local.cluster_name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_cluster.this]
}


###############################################################################
# Node group IAM role example                                                #
###############################################################################
resource "aws_iam_role" "eks_nodegroup" {
  name = "${var.name}-eks-nodegroup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach required policies to the node group role
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

# Example of attaching a custom inline policy statement
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

###############################################################################
# EKS Managed Node Group (replacing eks_managed_node_groups in the module)    #
###############################################################################
resource "aws_eks_node_group" "core_nodegroup" {
  cluster_name    = local.cluster_name
  node_group_name_prefix = "core_nodegroup"
  node_role_arn   = aws_iam_role.eks_nodegroup.arn
  subnet_ids      = concat(data.aws_subnets.private.ids)

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 4
  }

  # Architecture-sensitive instance types + AMI type
  instance_types = [
    var.architecture == "x86" ? "t3.medium" : "t4g.medium"
  ]
  ami_type = var.architecture == "x86" ? "AL2_X86_64" : "AL2_ARM_64"

  # Use depends_on to ensure the VPC CNI add-on is installed before node creation
  # If we're creating the cluster, ensure the cluster resource is built first.
  # If we're using an existing cluster, the depends_on is effectively empty.
  depends_on = [aws_eks_cluster.this, aws_iam_role.eks_nodegroup, aws_iam_role_policy_attachment.eks_nodegroup_worker_policy, aws_iam_role_policy_attachment.eks_nodegroup_cni_policy, aws_iam_role_policy_attachment.eks_nodegroup_ec2_registry, aws_iam_role_policy_attachment.eks_nodegroup_ssm, aws_iam_policy_attachment.nodegroup_ecr_ptc_attach, kubernetes_config_map.aws_auth]#, aws_iam_role_policy_attachment.eks_cluster_policy_2]

  # Example tags
  tags = local.tags
}



