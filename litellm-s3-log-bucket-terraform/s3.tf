# Create an S3 bucket similar to the CDK stack
resource "aws_s3_bucket" "log_bucket" {
  # If you'd like Terraform to generate a unique name, 
  # omit 'bucket' or set it to a var/log_bucket_name that you define.
  bucket_prefix = "litellm-logs-"
  force_destroy = true
}

