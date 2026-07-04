output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "ecs_service_sg_id" {
  value = aws_security_group.ecs_service.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "redis_sg_id" {
  value = aws_security_group.redis.id
}

output "ecs_task_execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "ecs_api_task_role_arn" {
  description = "App task role (S3) for api/worker/telephony."
  value       = aws_iam_role.app_task.arn
}

output "ecs_default_task_role_arn" {
  description = "Minimal task role for the ui service."
  value       = aws_iam_role.ui_task.arn
}

output "github_terraform_role_arn" {
  value = aws_iam_role.github_terraform.arn
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}
