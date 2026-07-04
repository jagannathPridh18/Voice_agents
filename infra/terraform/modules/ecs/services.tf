locals {
  net_private = {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_service_sg_id]
    assign_public_ip = false
  }
}

# --- api --------------------------------------------------------------------
resource "aws_ecs_service" "api" {
  name            = "${var.name_prefix}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 90

  network_configuration {
    subnets          = local.net_private.subnets
    security_groups  = local.net_private.security_groups
    assign_public_ip = local.net_private.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.api_port
  }

  service_registries {
    registry_arn = aws_service_discovery_service.api.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.https]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# --- ui ---------------------------------------------------------------------
resource "aws_ecs_service" "ui" {
  name            = "${var.name_prefix}-ui"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.ui.arn
  desired_count   = var.ui_desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = local.net_private.subnets
    security_groups  = local.net_private.security_groups
    assign_public_ip = local.net_private.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "ui"
    container_port   = var.ui_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.https]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# --- worker -----------------------------------------------------------------
resource "aws_ecs_service" "worker" {
  name            = "${var.name_prefix}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.net_private.subnets
    security_groups  = local.net_private.security_groups
    assign_public_ip = local.net_private.assign_public_ip
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# --- telephony (singleton) --------------------------------------------------
resource "aws_ecs_service" "telephony" {
  name            = "${var.name_prefix}-telephony"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.telephony.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Singleton: never run two. Stop old, start new (brief gap on deploy).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.net_private.subnets
    security_groups  = local.net_private.security_groups
    assign_public_ip = local.net_private.assign_public_ip
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}

# --- orchestrator (singleton) -----------------------------------------------
resource "aws_ecs_service" "orchestrator" {
  name            = "${var.name_prefix}-orchestrator"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.orchestrator.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.net_private.subnets
    security_groups  = local.net_private.security_groups
    assign_public_ip = local.net_private.assign_public_ip
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}

# ---------------------------------------------------------------------------
# Autoscaling (target-tracking on CPU) for the scalable services
# ---------------------------------------------------------------------------
locals {
  scalable = {
    api    = { min = var.api_desired_count, max = var.api_max_count, service = aws_ecs_service.api.name }
    ui     = { min = var.ui_desired_count, max = var.ui_max_count, service = aws_ecs_service.ui.name }
    worker = { min = var.worker_desired_count, max = var.worker_max_count, service = aws_ecs_service.worker.name }
  }
}

resource "aws_appautoscaling_target" "svc" {
  for_each           = local.scalable
  max_capacity       = each.value.max
  min_capacity       = each.value.min
  resource_id        = "service/${aws_ecs_cluster.this.name}/${each.value.service}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each           = local.scalable
  name               = "${var.name_prefix}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.svc[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.svc[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.svc[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
