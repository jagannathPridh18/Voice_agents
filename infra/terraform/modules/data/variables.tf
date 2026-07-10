variable "name_prefix" {
  type = string
}

variable "secret_name_prefix" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "redis_sg_id" {
  type = string
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage" {
  type = number
}

variable "db_max_allocated_storage" {
  type = number
}

variable "db_engine_version" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_multi_az" {
  type = bool
}

variable "redis_node_type" {
  type = string
}

variable "redis_engine_version" {
  type = string
}

variable "s3_bucket_name" {
  type = string
}

variable "app_origin" {
  description = "App URL used for the S3 CORS allowed origin."
  type        = string
}

variable "optional_secret_names" {
  description = "Empty secrets created for operators to populate later."
  type        = list(string)
  default     = ["SENTRY_DSN", "POSTHOG_API_KEY", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_HOST"]
}
