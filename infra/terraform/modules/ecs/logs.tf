locals {
  services = ["api", "ui", "worker", "telephony", "orchestrator", "migrate"]
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each          = toset(local.services)
  name              = "/ecs/${var.name_prefix}/${each.value}"
  retention_in_days = var.log_retention_days
}
