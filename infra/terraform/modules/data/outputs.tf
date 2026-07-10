output "db_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "s3_bucket_name" {
  value = aws_s3_bucket.audio.id
}

output "database_url_secret_arn" {
  value = aws_secretsmanager_secret.database_url.arn
}

output "redis_url_secret_arn" {
  value = aws_secretsmanager_secret.redis_url.arn
}

output "oss_jwt_secret_arn" {
  value = aws_secretsmanager_secret.oss_jwt.arn
}

output "turn_secret_arn" {
  value = aws_secretsmanager_secret.turn_secret.arn
}

output "optional_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.optional : k => s.arn }
}
