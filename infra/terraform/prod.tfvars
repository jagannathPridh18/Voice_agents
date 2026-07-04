# Fill these in for your environment, then:
#   terraform apply -var-file=prod.tfvars
# (CI passes -var-file=prod.tfvars automatically.)

project     = "dograh"
environment = "prod"
region      = "us-east-1"

# --- DNS / TLS (REQUIRED) ---------------------------------------------------
# domain_name is the FQDN the app is served at; route53_zone_id owns it.
domain_name     = "app.example.com"
route53_zone_id = "ZXXXXXXXXXXXXX"
create_turn_dns = true
turn_subdomain  = "turn" # => turn.app.example.com -> coturn EIP

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
