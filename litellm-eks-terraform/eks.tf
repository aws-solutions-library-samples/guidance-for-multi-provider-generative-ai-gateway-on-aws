################################################################################
# Cluster
################################################################################
# Data source for existing EKS cluster (when importing)
data "aws_eks_cluster" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.existing_cluster_name
}

data "aws_eks_cluster_auth" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.existing_cluster_name
}

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

# Create new cluster or use existing
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  create = var.create_cluster

  cluster_name    = "${var.name}-cluster"
  cluster_version = var.create_cluster ? var.cluster_version : data.aws_eks_cluster.existing[0].version
  cluster_endpoint_private_access = var.create_cluster ? true : null
  # Only set these if creating a new cluster
  cluster_endpoint_public_access = var.create_cluster ? true : null
  cluster_enabled_log_types     = var.create_cluster ? ["api", "audit", "authenticator", "controllerManager", "scheduler"] : []

  enable_cluster_creator_admin_permissions = var.create_cluster ? true : null

  access_entries = var.create_cluster ? {
    eks-operators = {
      kubernetes_groups = ["eks-operators"]
      principal_arn     = aws_iam_role.eks_operators.arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    eks-developers = {
      kubernetes_groups = ["eks-developers"]
      principal_arn     = aws_iam_role.eks_developers.arn
      policy_associations = {
        cluster_view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
        namespace_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["default"]
          }
        }
      }
    }
  } : {
    eks-operators = null
    eks-developers = null
  }

  # EKS Addons - only for new clusters
  cluster_addons = var.create_cluster ? {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
  } : {}

  vpc_id = var.create_cluster ? var.vpc_id : data.aws_eks_cluster.existing[0].vpc_config[0].vpc_id
  subnet_ids = var.create_cluster ? concat(data.aws_subnets.private.ids, data.aws_subnets.public.ids) : data.aws_eks_cluster.existing[0].vpc_config[0].subnet_ids

  # Node groups are always created/managed
  eks_managed_node_groups = {
    core_nodegroup = {
      description = "EKS Core Managed Node Group for hosting system add-ons"
      
      # Match CDK instance type configuration
      instance_types = [var.architecture == "x86" ? "t3.medium" : "t4g.medium"]
      ami_type       = var.architecture == "x86" ? "AL2_X86_64" : "AL2_ARM_64"

      min_size     = 1
      max_size     = 3
      desired_size = 1

      iam_role_attach_cni_policy = true
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
      iam_role_policy_statements = [
        {
          sid    = "ECRPullThroughCache"
          effect = "Allow"
          actions = [
            "ecr:CreateRepository",
            "ecr:BatchImportUpstreamImage",
          ]
          resources = ["*"]
        }
      ]

      ebs_optimized     = true
      enable_monitoring = true


      tags = local.tags
    }
  }
}


