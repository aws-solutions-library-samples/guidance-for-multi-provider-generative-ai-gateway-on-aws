###############################################################################
# S3 bucket for config
###############################################################################
resource "aws_s3_bucket" "config_bucket" {
  bucket_prefix = "litellm-config-"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.config_bucket.id

  rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
}


# Single file upload of `config.yaml`
# In your CDK, you used s3deploy with `include: ['config.yaml']` and `exclude: ['*']` then re-included `config.yaml`.
resource "aws_s3_object" "config_file" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "config.yaml"
  source = "${path.module}/../../../config/config.yaml"  # Adjust path as needed
  etag   = filemd5("${path.module}/../../../config/config.yaml")
}