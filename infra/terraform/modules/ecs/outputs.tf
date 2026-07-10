output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "api_target_group_arn_suffix" {
  value = aws_lb_target_group.api.arn_suffix
}

output "ui_target_group_arn_suffix" {
  value = aws_lb_target_group.ui.arn_suffix
}

output "api_service_name" {
  value = aws_ecs_service.api.name
}

output "ui_service_name" {
  value = aws_ecs_service.ui.name
}

output "worker_service_name" {
  value = aws_ecs_service.worker.name
}

output "telephony_service_name" {
  value = aws_ecs_service.telephony.name
}

output "orchestrator_service_name" {
  value = aws_ecs_service.orchestrator.name
}

output "migrate_task_definition_arn" {
  value = aws_ecs_task_definition.migrate.arn
}

output "api_log_group_name" {
  value = aws_cloudwatch_log_group.svc["api"].name
}
