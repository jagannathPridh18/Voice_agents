locals {
  database_url = "postgresql+asyncpg://${var.db_username}:${random_password.db.result}@${aws_db_instance.this.address}:5432/${var.db_name}"
  redis_url    = "rediss://:${random_password.redis_auth.result}@${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
}

resource "random_password" "oss_jwt" {
  length  = 64
  special = false
}

resource "random_password" "turn_secret" {
  length  = 48
  special = false
}

# --- Connection + app secrets (managed by Terraform) ------------------------
resource "aws_secretsmanager_secret" "database_url" {
  name                    = "${var.secret_name_prefix}/DATABASE_URL"
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id     = aws_secretsmanager_secret.database_url.id
  secret_string = local.database_url
}

resource "aws_secretsmanager_secret" "redis_url" {
  name                    = "${var.secret_name_prefix}/REDIS_URL"
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret_version" "redis_url" {
  secret_id     = aws_secretsmanager_secret.redis_url.id
  secret_string = local.redis_url
}

resource "aws_secretsmanager_secret" "oss_jwt" {
  name                    = "${var.secret_name_prefix}/OSS_JWT_SECRET"
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret_version" "oss_jwt" {
  secret_id     = aws_secretsmanager_secret.oss_jwt.id
  secret_string = random_password.oss_jwt.result
}

resource "aws_secretsmanager_secret" "turn_secret" {
  name                    = "${var.secret_name_prefix}/TURN_SECRET"
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret_version" "turn_secret" {
  secret_id     = aws_secretsmanager_secret.turn_secret.id
  secret_string = random_password.turn_secret.result
}

# --- Optional secrets: created empty, operators fill them later -------------
resource "aws_secretsmanager_secret" "optional" {
  for_each                = toset(var.optional_secret_names)
  name                    = "${var.secret_name_prefix}/${each.value}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "optional" {
  for_each      = aws_secretsmanager_secret.optional
  secret_id     = each.value.id
  secret_string = "REPLACE_ME"

  # Don't clobber values operators set out-of-band in the console/CLI.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
