variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "alarm_email" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_names" {
  type = list(string)
}

variable "alb_arn_suffix" {
  type = string
}

variable "api_tg_arn_suffix" {
  type = string
}

variable "ui_tg_arn_suffix" {
  type = string
}

variable "api_log_group_name" {
  type = string
}
