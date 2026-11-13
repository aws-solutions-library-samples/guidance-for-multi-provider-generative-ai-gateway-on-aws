# Config bucket: versioned (a bad config can be rolled back), private, TLS-only,
# kept on destroy while deletion protection is on. The app root module renders the LiteLLM
# config (one content-addressed config-<sha16>.yaml per change) and uploads it
# here — the foundation only provides the bucket.

resource "aws_s3_bucket" "config" {
  bucket_prefix = "${var.deployment_name}-config-"
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  bucket     = aws_s3_bucket.config.id
  depends_on = [aws_s3_bucket_public_access_block.config]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnforceSSLOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.config.arn,
        "${aws_s3_bucket.config.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# The app writes one content-addressed config object per change and never
# deletes earlier ones, so every task-definition revision can still load its
# own config. Only noncurrent versions (overwritten or deleted objects) expire;
# current objects never do, which would remove a live config.
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}

