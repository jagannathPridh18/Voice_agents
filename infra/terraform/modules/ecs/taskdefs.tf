locals {
  app_env_list = [for k, v in var.app_env : { name = k, value = v }]
  ui_env_list  = [for k, v in var.ui_env : { name = k, value = v }]

  secrets_all      = [for k, v in var.app_secrets : { name = k, valueFrom = v }]
  secrets_db_redis = [for k in ["DATABASE_URL", "REDIS_URL"] : { name = k, valueFrom = var.app_secrets[k] }]
  secrets_worker   = [for k in ["DATABASE_URL", "REDIS_URL", "OSS_JWT_SECRET"] : { name = k, valueFrom = var.app_secrets[k] }]
  # migrate imports api.constants, which reads REDIS_URL as required-to-boot,
  # so the migration task needs both DATABASE_URL and REDIS_URL.
  secrets_migrate = local.secrets_db_redis

  # awslogs config builder
  logcfg = { for s in local.services : s => {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.svc[s].name
      "awslogs-region"        = var.region
      "awslogs-stream-prefix" = s
    }
  } }
}

# --- api: uvicorn (public via ALB + Cloud Map) ------------------------------
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.api_cpu)
  memory                   = tostring(var.api_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.api_task_role_arn

  container_definitions = jsonencode([{
    name             = "api"
    image            = var.api_image
    essential        = true
    command          = ["uvicorn", "api.app:app", "--host", "0.0.0.0", "--port", tostring(var.api_port), "--workers", tostring(var.uvicorn_workers)]
    environment      = local.app_env_list
    secrets          = local.secrets_all
    portMappings     = [{ containerPort = var.api_port, protocol = "tcp" }]
    logConfiguration = local.logcfg["api"]
  }])
}

# --- ui: Next.js standalone (public via ALB default) ------------------------
resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.name_prefix}-ui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.ui_cpu)
  memory                   = tostring(var.ui_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.default_task_role_arn

  container_definitions = jsonencode([{
    name             = "ui"
    image            = var.ui_image
    essential        = true
    environment      = local.ui_env_list
    portMappings     = [{ containerPort = var.ui_port, protocol = "tcp" }]
    logConfiguration = local.logcfg["ui"]
  }])
}

# --- worker: ARQ background jobs --------------------------------------------
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name_prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.worker_cpu)
  memory                   = tostring(var.worker_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.api_task_role_arn

  container_definitions = jsonencode([{
    name             = "worker"
    image            = var.api_image
    essential        = true
    command          = ["python", "-m", "arq", "api.tasks.arq.WorkerSettings", "--custom-log-dict", "api.tasks.arq.LOG_CONFIG"]
    environment      = local.app_env_list
    secrets          = local.secrets_worker
    logConfiguration = local.logcfg["worker"]
  }])
}

# --- telephony: ari_manager singleton ---------------------------------------
resource "aws_ecs_task_definition" "telephony" {
  family                   = "${var.name_prefix}-telephony"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.telephony_cpu)
  memory                   = tostring(var.telephony_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.api_task_role_arn

  container_definitions = jsonencode([{
    name             = "telephony"
    image            = var.api_image
    essential        = true
    command          = ["python", "-m", "api.services.telephony.ari_manager"]
    environment      = local.app_env_list
    secrets          = local.secrets_db_redis
    logConfiguration = local.logcfg["telephony"]
  }])
}

# --- orchestrator: campaign_orchestrator singleton --------------------------
resource "aws_ecs_task_definition" "orchestrator" {
  family                   = "${var.name_prefix}-orchestrator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.telephony_cpu)
  memory                   = tostring(var.telephony_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.api_task_role_arn

  container_definitions = jsonencode([{
    name             = "orchestrator"
    image            = var.api_image
    essential        = true
    command          = ["python", "-m", "api.services.campaign.campaign_orchestrator"]
    environment      = local.app_env_list
    secrets          = local.secrets_db_redis
    logConfiguration = local.logcfg["orchestrator"]
  }])
}

# --- migrate: one-off alembic upgrade (run by CI before rolling services) ---
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name_prefix}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.api_task_role_arn

  container_definitions = jsonencode([{
    name             = "migrate"
    image            = var.api_image
    essential        = true
    command          = ["alembic", "-c", "api/alembic.ini", "upgrade", "head"]
    environment      = local.app_env_list
    secrets          = local.secrets_migrate
    logConfiguration = local.logcfg["migrate"]
  }])
}
