variable "name_prefix" {
  type = string
}
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "allowed_sg_id" {
  description = "Security group (ECS tasks) allowed to mount the EFS over NFS."
  type        = string
}

# Shared filesystem so the api (writes call recordings) and the worker (uploads
# them) — separate Fargate tasks — can exchange the temp files. Replaces the
# single-container shared /tmp the docker-compose deployment relies on.
resource "aws_efs_file_system" "this" {
  creation_token = "${var.name_prefix}-shared"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_7_DAYS"
  }

  tags = { Name = "${var.name_prefix}-shared" }
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-efs-sg"
  description = "NFS from ECS tasks to EFS"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.allowed_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-efs-sg" }
}

resource "aws_efs_mount_target" "this" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# Access point rooted at /shared, world-writable so the api/worker containers
# (same dograh uid, since they share the image) can exchange recording files.
resource "aws_efs_access_point" "shared" {
  file_system_id = aws_efs_file_system.this.id

  root_directory {
    path = "/shared"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "0777"
    }
  }

  tags = { Name = "${var.name_prefix}-shared-ap" }
}

output "file_system_id" {
  value = aws_efs_file_system.this.id
}

output "access_point_id" {
  value = aws_efs_access_point.shared.id
}

output "mount_target_ids" {
  value = aws_efs_mount_target.this[*].id
}
