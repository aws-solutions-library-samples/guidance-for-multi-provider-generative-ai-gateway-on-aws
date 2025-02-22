resource "aws_kms_key" "eks_secrets" {
count = var.create_cluster ? 1 : 0
  description             = "KMS key for encrypting EKS Secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Key policy that allows:
  # - Root to do anything (standard practice)
  # - The EKS cluster role to use the key for encryption (kms:Encrypt, kms:Decrypt, etc.)
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-default-1"
    Statement = [
      {
        Sid      = "Enable IAM User Permissions"
        Effect   = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow use of the key by EKS Cluster Role"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.eks_cluster[0].arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })
}
