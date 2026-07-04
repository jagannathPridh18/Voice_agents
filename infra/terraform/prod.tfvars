# Fill these in for your environment, then:
#   terraform apply -var-file=prod.tfvars
# (CI passes -var-file=prod.tfvars automatically.)

project     = "dograh"
environment = "prod"
region      = "ap-south-1"

# --- DNS / TLS --------------------------------------------------------------
# chatbucket.chat DNS is on Cloudflare, so DNS is managed externally: Terraform
# issues the ACM cert and waits for you to add the validation record + app
# record in Cloudflare (see the terraform outputs after apply).
domain_name            = "app.chatbucket.chat"
create_route53_records = false
create_turn_dns        = false # TURN_HOST uses the coturn Elastic IP directly

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
