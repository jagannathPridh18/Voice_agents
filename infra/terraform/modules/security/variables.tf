variable "name_prefix" {
  type = string
}

variable "project" {
  description = "Project name (used to scope the Terraform-state S3 bucket + lock table ARNs)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}

variable "api_port" {
  type = number
}

variable "ui_port" {
  type = number
}

variable "s3_bucket_arn" {
  description = "Constructed S3 bucket ARN (no data-module dependency)."
  type        = string
}

variable "secret_arn_prefix" {
  description = "Constructed Secrets Manager ARN glob for this env's secrets."
  type        = string
}
