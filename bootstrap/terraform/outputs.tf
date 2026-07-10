output "state_bucket" {
  description = "S3 bucket for Terraform remote state — set as `bucket` in infra/terraform/backend.tf."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table for state locking — set as `dynamodb_table` in infra/terraform/backend.tf."
  value       = aws_dynamodb_table.locks.name
}

output "region" {
  description = "Region the backend lives in — set as `region` in infra/terraform/backend.tf."
  value       = var.region
}
