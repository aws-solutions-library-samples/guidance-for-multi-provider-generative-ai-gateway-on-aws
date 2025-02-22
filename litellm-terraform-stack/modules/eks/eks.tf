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

resource "aws_ec2_tag" "public_subnet_elb" {
  for_each    = var.public_load_balancer ? toset(var.public_subnet_ids) : toset([])
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnet_internal_elb" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnets_cluster" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${local.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnets_cluster" {
  for_each    = toset(var.public_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${local.cluster_name}"
  value       = "shared"
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

  access_config {
    authentication_mode = "API"
  }

  name     = "${var.name}-cluster"
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster[0].arn

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets[0].arn
    }
    resources = ["secrets"]
  }

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
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy.eks_cluster_kms_policy
  ]
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

###############################################################################
# EKS Addons (replacing cluster_addons in the module)                         #
###############################################################################
resource "aws_eks_addon" "coredns" {
  count = var.create_cluster || var.install_add_ons_in_existing_eks_cluster ? 1 : 0

  cluster_name = local.cluster_name
  addon_name   = "coredns"

  # If we create the cluster, wait for it & the node group. Otherwise no wait.
  depends_on = [aws_eks_cluster.this, aws_eks_node_group.core_nodegroup, helm_release.aws_load_balancer_controller]
}

resource "aws_eks_addon" "kube_proxy" {
  count = var.create_cluster || var.install_add_ons_in_existing_eks_cluster ? 1 : 0

  cluster_name = local.cluster_name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_addon" "vpc_cni" {
  count = var.create_cluster || var.install_add_ons_in_existing_eks_cluster ? 1 : 0

  cluster_name = local.cluster_name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_addon" "pod_identity_agent" {
  count = var.create_cluster || var.install_add_ons_in_existing_eks_cluster ? 1 : 0

  cluster_name = local.cluster_name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [aws_eks_cluster.this]
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
    desired_size = var.desired_capacity
    min_size     = var.min_capacity
    max_size     = var.max_capacity
  }

  # Architecture-sensitive instance types + AMI type
  instance_types = [
    var.architecture == "x86" ? var.x86_instance_type : var.arm_instance_type
  ]
  ami_type = var.architecture == "x86" ? var.x86_ami_type : var.arm_ami_type

  depends_on = [
    aws_eks_access_entry.developers, 
    aws_eks_access_entry.operators,
    aws_eks_cluster.this,
    aws_eks_access_entry.admin,
    aws_eks_access_policy_association.admin_policy
  ]
}

resource "aws_eks_access_entry" "developers" {
  cluster_name      = local.cluster_name
  principal_arn     = aws_iam_role.eks_developers.arn
  type              = "STANDARD"
  user_name         = "eks-developers"
  kubernetes_groups = ["eks-developers"]
}

resource "aws_eks_access_entry" "operators" {
  cluster_name      = local.cluster_name
  principal_arn     = aws_iam_role.eks_operators.arn
  type              = "STANDARD"
  user_name         = "eks-operators"
  kubernetes_groups = ["eks-operators"]
}

locals {
  # Split the ARN into components
  arn_parts = split(":", data.aws_caller_identity.current.arn)
  
  # Determine if this is a user or assumed role
  is_assumed_role = length(regexall("assumed-role", local.arn_parts[5])) > 0
  
  role_name = split("/", data.aws_caller_identity.current.arn)[1]
  # Construct the appropriate ARN
  principal_arn = local.is_assumed_role ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.role_name}" : data.aws_caller_identity.current.arn
}


resource "aws_eks_access_entry" "admin" {
  count = var.create_cluster ? 1 : 0
  cluster_name      = local.cluster_name
  principal_arn = local.principal_arn
  type              = "STANDARD"
  user_name         = "admin-user"
}

# 2) Associate the AmazonEKSClusterAdminPolicy to that entry
resource "aws_eks_access_policy_association" "admin_policy" {
  count = var.create_cluster ? 1 : 0
  cluster_name  = local.cluster_name
  principal_arn = aws_eks_access_entry.admin[0].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}