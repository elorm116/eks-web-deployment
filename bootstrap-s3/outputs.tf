output "bucket_name" {
  value       = aws_s3_bucket.state.id
  description = "S3 bucket name for Terraform state"
}

output "bucket_arn" {
  value       = aws_s3_bucket.state.arn
  description = "S3 bucket ARN"
}