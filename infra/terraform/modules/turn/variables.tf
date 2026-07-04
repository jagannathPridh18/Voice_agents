variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "region" {
  type = string
}

variable "turn_secret_arn" {
  type = string
}

variable "realm" {
  description = "TURN realm (the app domain)."
  type        = string
}

variable "relay_port_min" {
  type = number
}

variable "relay_port_max" {
  type = number
}

variable "ssh_cidr" {
  description = "CIDR allowed SSH. Empty = no SSH ingress (use SSM Session Manager)."
  type        = string
  default     = ""
}

variable "key_name" {
  type    = string
  default = ""
}

variable "log_retention_days" {
  type = number
}
