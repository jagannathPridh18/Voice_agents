# Fill these in for your environment, then:
#   terraform apply -var-file=prod.tfvars
# (CI passes -var-file=prod.tfvars automatically.)

project     = "dograh"
environment = "prod"
region      = "ap-south-1"

# --- DNS / TLS --------------------------------------------------------------
# Deploy HTTP-only for now (no DNS dependency); the stack comes up on the ALB
# URL. Once chatbucket.chat DNS is set up in Cloudflare, add the validation +
# app records, set enable_https = true, and re-apply to serve https on the
# domain.
domain_name            = "app.chatbucket.chat"
enable_https           = false
create_route53_records = false
create_turn_dns        = false # TURN_HOST uses the coturn Elastic IP directly

# An OIDC provider for GitHub Actions already exists in this account.
create_github_oidc_provider = false

# --- CI/CD (REQUIRED) -------------------------------------------------------
# Must match the repo hosting the workflows — this is what the OIDC role trusts.
github_org  = "jagannathPridh18"
github_repo = "Voice_agents"

# --- Sizing (tune as needed) ------------------------------------------------
api_desired_count    = 2
ui_desired_count     = 2
worker_desired_count = 1
db_instance_class    = "db.t3.medium"
redis_node_type      = "cache.t3.micro"
coturn_instance_type = "t3.small"

# --- Ops --------------------------------------------------------------------
alarm_email        = "" # e.g. "oncall@example.com" to receive alarm emails
log_retention_days = 30
enable_telemetry   = false
