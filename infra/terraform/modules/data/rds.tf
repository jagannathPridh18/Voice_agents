locals {
  pg_family = "postgres${split(".", var.db_engine_version)[0]}"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${var.name_prefix}-db-subnets" }
}

# Custom parameter group so ops can tune later. pgvector does NOT require
# shared_preload_libraries — the `vector` extension is created by the app's
# Alembic migration (CREATE EXTENSION IF NOT EXISTS vector).
resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg"
  family      = local.pg_family
  description = "Dograh Postgres params"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log queries slower than 1s
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "-_" # keep the password URL-safe for DATABASE_URL
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period    = 7
  backup_window              = "03:00-04:00"
  maintenance_window         = "sun:04:30-sun:05:30"
  auto_minor_version_upgrade = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-pg-final"

  performance_insights_enabled = true
  copy_tags_to_snapshot        = true

  tags = { Name = "${var.name_prefix}-pg" }
}
