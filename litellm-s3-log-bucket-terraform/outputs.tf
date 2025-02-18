# Outputs to match the CDK stack's CfnOutput
output "LogBucketName" {
  description = "The name of the Log S3 bucket"
  value       = aws_s3_bucket.log_bucket.bucket
}

output "LogBucketArn" {
  description = "The ARN of the Log S3 bucket"
  value       = aws_s3_bucket.log_bucket.arn
}