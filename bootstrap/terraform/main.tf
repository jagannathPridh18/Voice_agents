# Bootstrap: creates the remote-state backend (S3 bucket + DynamoDB lock table)
# that infra/terraform/backend.tf points at. Run this ONCE with local state:
#
#   cd bootstrap/terraform
#   terraform init
#   terraform apply -var="project=dograh" -var="region=us-east-1"
#
# Then configure infra/terraform to use the outputs below.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "tf-state-backend"
    }
  }
}

locals {
  state_bucket = "${var.project}-tf-state-${data.aws_caller_identity.current.account_id}"
  lock_table   = "${var.project}-tf-locks"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # State is the source of truth for the whole environment — never let a
  # `terraform destroy` of this root nuke it by accident.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}
