###############################################################################
# S3 bucket for config
###############################################################################
resource "aws_s3_bucket" "config_bucket" {
  bucket_prefix = "litellm-config-"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config_bucket" {
  bucket = aws_s3_bucket.config_bucket.id

  rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
}

resource "aws_s3_bucket_policy" "config_bucket" {
  bucket = aws_s3_bucket.config_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceSSLOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.config_bucket.arn,
          "${aws_s3_bucket.config_bucket.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_public_access_block" "config_bucket" {
  bucket = aws_s3_bucket.config_bucket.id
  block_public_acls   = true
  block_public_policy = true
}

# Single file upload of `config.yaml`
# In your CDK, you used s3deploy with `include: ['config.yaml']` and `exclude: ['*']` then re-included `config.yaml`.
resource "aws_s3_object" "config_file" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "config.yaml"
  source = "${path.module}/../../../config/config.yaml"  # Adjust path as needed
  etag   = filemd5("${path.module}/../../../config/config.yaml")
}