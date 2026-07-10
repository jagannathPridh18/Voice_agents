locals {
  metric_namespace = "Dograh/${var.name_prefix}"
}

# --- Alarm notifications ----------------------------------------------------
resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- Application error rate (log metric filter on api logs) -----------------
resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "${var.name_prefix}-api-errors"
  log_group_name = var.api_log_group_name
  pattern        = "?ERROR ?CRITICAL ?Traceback"

  metric_transformation {
    name          = "ApiErrors"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "${var.name_prefix}-api-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApiErrors"
  namespace           = local.metric_namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 25
  alarm_description   = "api logged >25 ERROR/CRITICAL/Traceback lines in 5m"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# --- ALB 5xx ----------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB returned >10 5XX in 5m"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# --- Unhealthy targets ------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_unhealthy" {
  alarm_name          = "${var.name_prefix}-api-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "api target group has unhealthy hosts"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.api_tg_arn_suffix
  }
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- Per-service CPU --------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "svc_cpu" {
  for_each            = toset(var.service_names)
  alarm_name          = "${each.value}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "${each.value} CPU > 85% for 3m"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = each.value
  }
  alarm_actions = [aws_sns_topic.alarms.arn]
}

# --- Dashboard --------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "ALB requests + 5xx"
          region = var.region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
          ]
          period = 60, stat = "Sum", view = "timeSeries"
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "ALB target response time (p95)"
          region = var.region
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix],
          ]
          period = 60, stat = "p95", view = "timeSeries"
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title   = "ECS CPU by service"
          region  = var.region
          period  = 60, stat = "Average", view = "timeSeries"
          metrics = [for s in var.service_names : ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", s]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title   = "ECS Memory by service"
          region  = var.region
          period  = 60, stat = "Average", view = "timeSeries"
          metrics = [for s in var.service_names : ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", s]]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6,
        properties = {
          title  = "Recent api errors"
          region = var.region
          query  = "SOURCE '${var.api_log_group_name}' | fields @timestamp, @message | filter @message like /ERROR|CRITICAL|Traceback/ | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}

output "sns_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}
