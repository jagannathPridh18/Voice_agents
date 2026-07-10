resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-redis-subnets"
  subnet_ids = var.private_subnet_ids
}

# AUTH token must be alphanumeric-safe (no /, @, ", space). special=false keeps
# it URL-safe for REDIS_URL too.
resource "random_password" "redis_auth" {
  length  = 40
  special = false
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Dograh Redis (ARQ queue + worker pub/sub + ARI state)"

  engine         = "redis"
  engine_version = var.redis_engine_version
  node_type      = var.redis_node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.redis_sg_id]

  # TLS + AUTH — REDIS_URL uses rediss:// (handled in api/tasks/arq.py).
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  snapshot_retention_limit = 3
  maintenance_window       = "sun:05:30-sun:06:30"

  apply_immediately = true

  tags = { Name = "${var.name_prefix}-redis" }
}
