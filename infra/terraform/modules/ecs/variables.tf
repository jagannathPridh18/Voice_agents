variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "ecs_service_sg_id" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "api_task_role_arn" {
  type = string
}

variable "default_task_role_arn" {
  type = string
}

variable "api_image" {
  type = string
}

variable "ui_image" {
  type = string
}

variable "api_port" {
  type = number
}

variable "ui_port" {
  type = number
}

variable "certificate_arn" {
  type    = string
  default = ""
}

variable "enable_https" {
  description = "Serve HTTPS (443) with the ACM cert. When false, the ALB is HTTP-only (80) — no cert/DNS needed."
  type        = bool
  default     = true
}

variable "cloudmap_namespace" {
  type = string
}

# Sizing
variable "api_cpu" { type = number }
variable "api_memory" { type = number }
variable "api_desired_count" { type = number }
variable "api_max_count" { type = number }
variable "ui_cpu" { type = number }
variable "ui_memory" { type = number }
variable "ui_desired_count" { type = number }
variable "ui_max_count" { type = number }
variable "worker_cpu" { type = number }
variable "worker_memory" { type = number }
variable "worker_desired_count" { type = number }
variable "worker_max_count" { type = number }
variable "telephony_cpu" { type = number }
variable "telephony_memory" { type = number }
variable "uvicorn_workers" { type = number }

variable "log_retention_days" {
  type = number
}

variable "app_env" {
  description = "Plaintext environment for the api-family tasks."
  type        = map(string)
}

variable "ui_env" {
  description = "Plaintext environment for the ui task."
  type        = map(string)
}

variable "app_secrets" {
  description = "name => Secrets Manager ARN, injected as container secrets."
  type        = map(string)
}
