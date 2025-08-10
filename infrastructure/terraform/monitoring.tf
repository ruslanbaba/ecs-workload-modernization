# CloudWatch Monitoring and Observability Configuration
# Enterprise-grade monitoring for ECS workload modernization

# CloudWatch Dashboards for each application
resource "aws_cloudwatch_dashboard" "application_overview" {
  dashboard_name = "${var.project_name}-application-overview"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        
        properties = {
          metrics = [
            for app in var.application_names : [
              "AWS/ECS", "CPUUtilization", "ServiceName", "${var.project_name}-${app}", "ClusterName", aws_ecs_cluster.main.name
            ]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "ECS Service CPU Utilization"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        
        properties = {
          metrics = [
            for app in var.application_names : [
              "AWS/ECS", "MemoryUtilization", "ServiceName", "${var.project_name}-${app}", "ClusterName", aws_ecs_cluster.main.name
            ]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "ECS Service Memory Utilization"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        
        properties = {
          metrics = [
            for app in var.application_names : [
              "AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.apps[app].arn_suffix
            ]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Application Response Times"
          period  = 300
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-dashboard"
  }
}

# CloudWatch Alarms for Critical Metrics
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ECS service CPU utilization for ${each.key}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    ServiceName = "${var.project_name}-${each.key}"
    ClusterName = aws_ecs_cluster.main.name
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-high-cpu-alarm"
    Application = each.key
    Severity    = "High"
  }
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = "300"
  statistic           = "Average"
  threshold           = "85"
  alarm_description   = "This metric monitors ECS service memory utilization for ${each.key}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    ServiceName = "${var.project_name}-${each.key}"
    ClusterName = aws_ecs_cluster.main.name
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-high-memory-alarm"
    Application = each.key
    Severity    = "High"
  }
}

resource "aws_cloudwatch_metric_alarm" "target_response_time" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-high-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Average"
  threshold           = "2"
  alarm_description   = "This metric monitors high response time for ${each.key}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-response-time-alarm"
    Application = each.key
    Severity    = "Medium"
  }
}

# SNS Topic for Alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  
  tags = {
    Name = "${var.project_name}-alerts"
  }
}

resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "alerts@company.com"
}

resource "aws_sns_topic_subscription" "slack_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "https"
  endpoint  = "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
}

# Custom CloudWatch Metrics for Business KPIs
resource "aws_cloudwatch_log_metric_filter" "deployment_success" {
  for_each = toset(var.application_names)
  
  name           = "${var.project_name}-${each.key}-deployment-success"
  log_group_name = aws_cloudwatch_log_group.app_logs[each.key].name
  pattern        = "[timestamp, request_id, level=\"INFO\", message=\"Deployment completed successfully\"]"
  
  metric_transformation {
    name      = "DeploymentSuccess"
    namespace = "ECS/Deployments"
    value     = "1"
    
    default_value = 0
  }
}

resource "aws_cloudwatch_log_metric_filter" "error_rate" {
  for_each = toset(var.application_names)
  
  name           = "${var.project_name}-${each.key}-error-rate"
  log_group_name = aws_cloudwatch_log_group.app_logs[each.key].name
  pattern        = "[timestamp, request_id, level=\"ERROR\", ...]"
  
  metric_transformation {
    name      = "ErrorRate"
    namespace = "Application/Errors"
    value     = "1"
    
    default_value = 0
  }
}

# X-Ray Tracing Configuration
resource "aws_xray_sampling_rule" "apps" {
  for_each = toset(var.application_names)
  
  rule_name      = "${var.project_name}-${each.key}-sampling"
  priority       = 9000
  version        = 1
  reservoir_size = 1
  fixed_rate     = 0.1
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = each.key
  resource_arn   = "*"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-xray-sampling"
    Application = each.key
  }
}

# Performance Insights for RDS
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "75"
  alarm_description   = "This metric monitors RDS CPU utilization for ${each.key}"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.apps[each.key].id
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-rds-cpu-alarm"
    Application = each.key
  }
}

# Cost Monitoring
resource "aws_cloudwatch_metric_alarm" "cost_anomaly" {
  alarm_name          = "${var.project_name}-cost-anomaly"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = "86400"
  statistic           = "Maximum"
  threshold           = "1000"
  alarm_description   = "This metric monitors estimated charges"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    Currency = "USD"
  }
  
  tags = {
    Name = "${var.project_name}-cost-anomaly-alarm"
  }
}

# CloudWatch Insights Queries
resource "aws_cloudwatch_query_definition" "error_analysis" {
  name = "${var.project_name}-error-analysis"
  
  log_group_names = [
    for app in var.application_names : aws_cloudwatch_log_group.app_logs[app].name
  ]
  
  query_string = <<EOF
fields @timestamp, @message, @logStream
| filter @message like /ERROR/
| stats count() by @logStream
| sort @timestamp desc
| limit 100
EOF
}

resource "aws_cloudwatch_query_definition" "performance_analysis" {
  name = "${var.project_name}-performance-analysis"
  
  log_group_names = [
    for app in var.application_names : aws_cloudwatch_log_group.app_logs[app].name
  ]
  
  query_string = <<EOF
fields @timestamp, @message, @duration
| filter @message like /response_time/
| stats avg(@duration), max(@duration), min(@duration) by bin(5m)
| sort @timestamp desc
EOF
}

# Container Insights Metrics
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/containerinsights/${aws_ecs_cluster.main.name}/performance"
  retention_in_days = var.log_retention_days
  
  tags = {
    Name = "${var.project_name}-container-insights"
  }
}
