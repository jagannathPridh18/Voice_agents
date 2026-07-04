output "app_url" {
  description = "Public URL of the application."
  value       = local.app_url
}

output "name_prefix" {
  description = "Resource name prefix (project-environment). Set as the NAME_PREFIX repo variable."
  value       = local.name_prefix
}

output "region" {
  description = "AWS region. Set as the AWS_REGION repo variable."
  value       = local.region
}

output "alb_dns_name" {
  description = "ALB DNS name. Point app record (CNAME app.<domain>) here at your DNS provider."
  value       = module.ecs.alb_dns_name
}

output "acm_validation_records" {
  description = "DNS record(s) to add at your DNS provider (Cloudflare) to validate the ACM cert."
  value       = module.dns.domain_validation_options
}

output "cloudflare_setup" {
  description = "Records to create in Cloudflare for external-DNS deployments."
  value = var.create_route53_records ? "managed in Route53" : join("\n", concat(
    [for r in module.dns.domain_validation_options : "1) CNAME (DNS-only)  ${r.name} -> ${r.value}"],
    ["2) CNAME (DNS-only)  ${var.domain_name} -> ${module.ecs.alb_dns_name}"],
  ))
}

output "ecr_api_repository_url" {
  description = "ECR repo for the api/worker/telephony/migrate image (push here from CI)."
  value       = module.ecr.api_repository_url
}

output "ecr_ui_repository_url" {
  description = "ECR repo for the ui image."
  value       = module.ecr.ui_repository_url
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_names" {
  description = "Map of ECS service names for CI `update-service` calls."
  value = {
    api          = module.ecs.api_service_name
    ui           = module.ecs.ui_service_name
    worker       = module.ecs.worker_service_name
    telephony    = module.ecs.telephony_service_name
    orchestrator = module.ecs.orchestrator_service_name
  }
}

output "migrate_task_definition" {
  description = "Task definition family for the one-off DB migration RunTask."
  value       = module.ecs.migrate_task_definition_arn
}

output "ecs_run_task_network" {
  description = "Network config CI needs for `aws ecs run-task` (migration)."
  value = {
    subnets         = module.network.private_subnet_ids
    security_groups = [module.security.ecs_service_sg_id]
  }
}

output "github_terraform_role_arn" {
  description = "IAM role for the Terraform workflow (broad infra perms). Set as AWS_TERRAFORM_ROLE_ARN repo variable."
  value       = module.security.github_terraform_role_arn
}

output "github_deploy_role_arn" {
  description = "IAM role for the app deploy workflow (ECR push + ECS roll). Set as AWS_DEPLOY_ROLE_ARN repo variable."
  value       = module.security.github_deploy_role_arn
}

output "coturn_public_ip" {
  description = "Elastic IP of the coturn TURN server (empty when deploy_coturn = false)."
  value       = local.coturn_ip
}

output "turn_host" {
  description = "Value wired into the api service's TURN_HOST."
  value       = local.turn_host
}

output "rds_endpoint" {
  value     = module.data.db_endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = module.data.redis_primary_endpoint
  sensitive = true
}

output "s3_bucket_name" {
  value = module.data.s3_bucket_name
}

output "optional_secret_arns" {
  description = "Empty optional secrets (SENTRY_DSN, POSTHOG_API_KEY, LANGFUSE_*) — populate values in the console/CLI, then they flow to the api task."
  value       = module.data.optional_secret_arns
}
