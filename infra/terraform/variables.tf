# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------
variable "project" {
  description = "Project name prefix for all resources."
  type        = string
  default     = "dograh"
}

variable "environment" {
  description = "Deployment environment (e.g. prod, staging). Also the state key prefix."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper) instead of one per AZ (HA)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# DNS / TLS
# ---------------------------------------------------------------------------
variable "domain_name" {
  description = "Public FQDN the app is served at, e.g. app.example.com."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name (only used when create_route53_records = true)."
  type        = string
  default     = ""
}

variable "create_route53_records" {
  description = "Manage DNS in Route53. Set false for external DNS (e.g. Cloudflare) — you add the cert-validation + app records at your provider."
  type        = bool
  default     = true
}

variable "enable_https" {
  description = "Serve HTTPS on your domain (needs the ACM cert validated via DNS). Set false to deploy HTTP-only on the ALB URL with no DNS dependency; flip to true once DNS is set up."
  type        = bool
  default     = true
}

variable "create_turn_dns" {
  description = "Create a DNS record pointing turn_subdomain.<zone> at the coturn Elastic IP."
  type        = bool
  default     = true
}

variable "turn_subdomain" {
  description = "Subdomain for the TURN server record (prefix onto the zone apex)."
  type        = string
  default     = "turn"
}

# ---------------------------------------------------------------------------
# CI/CD (GitHub OIDC trust)
# ---------------------------------------------------------------------------
variable "github_org" {
  description = "GitHub org/owner that hosts the repo (for OIDC role trust)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC role trust)."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false if the account already has one (only one per account is allowed)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------
variable "api_image_tag" {
  description = "Image tag deployed for the api/worker/telephony/migrate tasks. CI updates task defs directly, so this is mainly the initial value."
  type        = string
  default     = "latest"
}

variable "ui_image_tag" {
  description = "Image tag deployed for the ui task."
  type        = string
  default     = "latest"
}

# ---------------------------------------------------------------------------
# ECS sizing
# ---------------------------------------------------------------------------
variable "api_cpu" {
  type    = number
  default = 1024
}
variable "api_memory" {
  type    = number
  default = 2048
}
variable "api_desired_count" {
  type    = number
  default = 2
}
variable "api_max_count" {
  type    = number
  default = 6
}

variable "ui_cpu" {
  type    = number
  default = 512
}
variable "ui_memory" {
  type    = number
  default = 1024
}
variable "ui_desired_count" {
  type    = number
  default = 2
}
variable "ui_max_count" {
  type    = number
  default = 4
}

variable "worker_cpu" {
  type    = number
  default = 1024
}
variable "worker_memory" {
  type    = number
  default = 2048
}
variable "worker_desired_count" {
  type    = number
  default = 1
}
variable "worker_max_count" {
  type    = number
  default = 4
}

# Telephony runs the singleton ari_manager + campaign_orchestrator. Keep at 1.
variable "telephony_cpu" {
  type    = number
  default = 512
}
variable "telephony_memory" {
  type    = number
  default = 1024
}

variable "uvicorn_workers" {
  description = "uvicorn worker processes per api task."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# Data services
# ---------------------------------------------------------------------------
variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}
variable "db_allocated_storage" {
  type    = number
  default = 50
}
variable "db_max_allocated_storage" {
  type    = number
  default = 200
}
variable "db_engine_version" {
  type    = string
  default = "16.9"
}
variable "db_name" {
  type    = string
  default = "dograh"
}
variable "db_username" {
  type    = string
  default = "dograh"
}
variable "db_multi_az" {
  type    = bool
  default = false
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}
variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

# ---------------------------------------------------------------------------
# coturn
# ---------------------------------------------------------------------------
variable "deploy_coturn" {
  description = "Deploy the coturn TURN server (EC2). Set false to skip it (e.g. when the EC2 vCPU quota is maxed or WebRTC voice isn't needed yet)."
  type        = bool
  default     = true
}

variable "coturn_instance_type" {
  type    = string
  default = "t3.small"
}
variable "turn_relay_port_min" {
  type    = number
  default = 49152
}
variable "turn_relay_port_max" {
  type    = number
  default = 49200
}
variable "coturn_ssh_cidr" {
  description = "Optional CIDR allowed SSH (22) to the coturn box. Empty disables SSH."
  type        = string
  default     = ""
}
variable "coturn_key_name" {
  description = "Optional EC2 key pair name for coturn SSH access."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "alarm_email" {
  description = "Email subscribed to the CloudWatch alarm SNS topic. Empty disables the subscription."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# App configuration (plaintext env for the api service)
# ---------------------------------------------------------------------------
variable "deployment_mode" {
  type    = string
  default = "production"
}
variable "auth_provider" {
  type    = string
  default = "local"
}
variable "enable_telemetry" {
  type    = bool
  default = false
}
