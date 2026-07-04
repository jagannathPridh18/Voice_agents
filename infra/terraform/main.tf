locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name

  # Names are computed by convention so IAM policies in the security module can
  # grant on the resource ARNs without depending on the data module (avoids a
  # security <-> data dependency cycle).
  s3_bucket_name     = "${local.name_prefix}-voice-audio-${local.account_id}"
  secret_name_prefix = local.name_prefix
  s3_bucket_arn      = "arn:aws:s3:::${local.s3_bucket_name}"
  secret_arn_prefix  = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${local.name_prefix}/*"

  app_url   = "https://${var.domain_name}"
  turn_fqdn = "${var.turn_subdomain}.${var.domain_name}"
  turn_host = var.create_turn_dns ? local.turn_fqdn : module.coturn.public_ip
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  region             = local.region
}

# ---------------------------------------------------------------------------
# Security groups + IAM (OIDC, ECS roles)
# ---------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  name_prefix = local.name_prefix
  project     = var.project
  vpc_id      = module.network.vpc_id
  vpc_cidr    = var.vpc_cidr

  account_id                  = local.account_id
  region                      = local.region
  github_org                  = var.github_org
  github_repo                 = var.github_repo
  create_github_oidc_provider = var.create_github_oidc_provider

  api_port = 8000
  ui_port  = 3010

  s3_bucket_arn     = local.s3_bucket_arn
  secret_arn_prefix = local.secret_arn_prefix
}

# ---------------------------------------------------------------------------
# Data layer: RDS (pgvector), ElastiCache Redis, S3, Secrets Manager
# ---------------------------------------------------------------------------
module "data" {
  source = "./modules/data"

  name_prefix        = local.name_prefix
  secret_name_prefix = local.secret_name_prefix
  private_subnet_ids = module.network.private_subnet_ids

  rds_sg_id                = module.security.rds_sg_id
  redis_sg_id              = module.security.redis_sg_id
  db_instance_class        = var.db_instance_class
  db_allocated_storage     = var.db_allocated_storage
  db_max_allocated_storage = var.db_max_allocated_storage
  db_engine_version        = var.db_engine_version
  db_name                  = var.db_name
  db_username              = var.db_username
  db_multi_az              = var.db_multi_az

  redis_node_type      = var.redis_node_type
  redis_engine_version = var.redis_engine_version

  s3_bucket_name = local.s3_bucket_name
  app_origin     = local.app_url
}

# ---------------------------------------------------------------------------
# Container registries
# ---------------------------------------------------------------------------
module "ecr" {
  source      = "./modules/ecr"
  name_prefix = local.name_prefix
}

# ---------------------------------------------------------------------------
# coturn (TURN server) on EC2 + Elastic IP
# ---------------------------------------------------------------------------
module "coturn" {
  # Directory is modules/turn (not "coturn") because the repo .gitignore has a
  # `coturn/` rule that would exclude it from commits. Module name stays coturn.
  source = "./modules/turn"

  name_prefix      = local.name_prefix
  vpc_id           = module.network.vpc_id
  public_subnet_id = module.network.public_subnet_ids[0]
  instance_type    = var.coturn_instance_type
  region           = local.region

  turn_secret_arn = module.data.turn_secret_arn
  realm           = var.domain_name
  relay_port_min  = var.turn_relay_port_min
  relay_port_max  = var.turn_relay_port_max

  ssh_cidr           = var.coturn_ssh_cidr
  key_name           = var.coturn_key_name
  log_retention_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# TLS certificate (ACM, DNS-validated in the hosted zone)
# ---------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns"

  domain_name     = var.domain_name
  route53_zone_id = var.route53_zone_id
}

# ---------------------------------------------------------------------------
# ECS Fargate: cluster, task defs, services, ALB, Cloud Map, autoscaling
# ---------------------------------------------------------------------------
module "ecs" {
  source = "./modules/ecs"

  name_prefix = local.name_prefix
  region      = local.region

  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  alb_sg_id         = module.security.alb_sg_id
  ecs_service_sg_id = module.security.ecs_service_sg_id

  execution_role_arn    = module.security.ecs_task_execution_role_arn
  api_task_role_arn     = module.security.ecs_api_task_role_arn
  default_task_role_arn = module.security.ecs_default_task_role_arn

  api_image = "${module.ecr.api_repository_url}:${var.api_image_tag}"
  ui_image  = "${module.ecr.ui_repository_url}:${var.ui_image_tag}"

  api_port = 8000
  ui_port  = 3010

  certificate_arn = module.dns.certificate_arn

  # Sizing
  api_cpu              = var.api_cpu
  api_memory           = var.api_memory
  api_desired_count    = var.api_desired_count
  api_max_count        = var.api_max_count
  ui_cpu               = var.ui_cpu
  ui_memory            = var.ui_memory
  ui_desired_count     = var.ui_desired_count
  ui_max_count         = var.ui_max_count
  worker_cpu           = var.worker_cpu
  worker_memory        = var.worker_memory
  worker_desired_count = var.worker_desired_count
  worker_max_count     = var.worker_max_count
  telephony_cpu        = var.telephony_cpu
  telephony_memory     = var.telephony_memory
  uvicorn_workers      = var.uvicorn_workers

  log_retention_days = var.log_retention_days

  # Plaintext env
  app_env = {
    ENVIRONMENT          = var.environment == "prod" ? "production" : var.environment
    DEPLOYMENT_MODE      = var.deployment_mode
    AUTH_PROVIDER        = var.auth_provider
    LOG_LEVEL            = "INFO"
    LOG_TO_FILE          = "false"
    ENABLE_AWS_S3        = "true"
    S3_BUCKET            = local.s3_bucket_name
    S3_REGION            = local.region
    BACKEND_API_ENDPOINT = local.app_url
    UI_APP_URL           = local.app_url
    CORS_ALLOWED_ORIGINS = local.app_url
    ENABLE_TELEMETRY     = tostring(var.enable_telemetry)
    TURN_HOST            = local.turn_host
    SERVER_IP            = module.coturn.public_ip
    FORCE_TURN_RELAY     = "false"
    ENABLE_ARI_STASIS    = "true"
  }

  ui_env = {
    BACKEND_URL      = "http://api.${local.name_prefix}.internal:8000"
    NODE_ENV         = "production"
    ENABLE_TELEMETRY = tostring(var.enable_telemetry)
  }

  # Secrets (ARNs → injected as container `secrets`)
  app_secrets = {
    DATABASE_URL   = module.data.database_url_secret_arn
    REDIS_URL      = module.data.redis_url_secret_arn
    OSS_JWT_SECRET = module.data.oss_jwt_secret_arn
    TURN_SECRET    = module.data.turn_secret_arn
  }

  cloudmap_namespace = "${local.name_prefix}.internal"
}

# ---------------------------------------------------------------------------
# Observability: SNS, alarms, dashboard (log groups live in the ecs module)
# ---------------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  name_prefix = local.name_prefix
  region      = local.region
  alarm_email = var.alarm_email

  cluster_name = module.ecs.cluster_name
  service_names = [
    module.ecs.api_service_name,
    module.ecs.ui_service_name,
    module.ecs.worker_service_name,
    module.ecs.telephony_service_name,
    module.ecs.orchestrator_service_name,
  ]

  alb_arn_suffix     = module.ecs.alb_arn_suffix
  api_tg_arn_suffix  = module.ecs.api_target_group_arn_suffix
  ui_tg_arn_suffix   = module.ecs.ui_target_group_arn_suffix
  api_log_group_name = module.ecs.api_log_group_name
}

# ---------------------------------------------------------------------------
# DNS records (created here to avoid dns <-> ecs/coturn cycles)
# ---------------------------------------------------------------------------
resource "aws_route53_record" "app" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.ecs.alb_dns_name
    zone_id                = module.ecs.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "turn" {
  count   = var.create_turn_dns ? 1 : 0
  zone_id = var.route53_zone_id
  name    = local.turn_fqdn
  type    = "A"
  ttl     = 300
  records = [module.coturn.public_ip]
}
