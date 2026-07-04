variable "project" {
  description = "Project name prefix used for the state bucket and lock table."
  type        = string
  default     = "dograh"
}

variable "region" {
  description = "AWS region to create the state backend in."
  type        = string
  default     = "us-east-1"
}
