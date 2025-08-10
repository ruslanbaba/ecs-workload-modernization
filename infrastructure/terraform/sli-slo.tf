# SLI/SLO Implementation with Advanced Monitoring
# Comprehensive Service Level Indicators and Objectives

# Custom CloudWatch Dashboard for SLI/SLO monitoring
resource "aws_cloudwatch_dashboard" "sli_slo" {
  dashboard_name = "${var.project_name}-sli-slo-dashboard"
  
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
              "AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.apps[app].arn_suffix,
              "AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.apps[app].arn_suffix,
              "AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "TargetGroup", aws_lb_target_group.apps[app].arn_suffix,
              "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.apps[app].arn_suffix
            ]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Application Performance SLIs"
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
              "AWS/ECS", "CPUUtilization", "ServiceName", aws_ecs_service.apps[app].name, "ClusterName", aws_ecs_cluster.main.name,
              "AWS/ECS", "MemoryUtilization", "ServiceName", aws_ecs_service.apps[app].name, "ClusterName", aws_ecs_cluster.main.name
            ]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Resource Utilization SLIs"
          period  = 300
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-sli-slo-dashboard"
  }
}

# Lambda function for SLO calculation and reporting
resource "aws_lambda_function" "slo_calculator" {
  filename         = "slo-calculator.zip"
  function_name    = "${var.project_name}-slo-calculator"
  role            = aws_iam_role.slo_calculator.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 300
  memory_size      = 512
  
  environment {
    variables = {
      SLO_TARGETS = jsonencode({
        availability_slo    = "99.9"
        latency_p95_slo    = "500"  # milliseconds
        latency_p99_slo    = "1000" # milliseconds
        error_rate_slo     = "0.1"  # percentage
      })
      CLOUDWATCH_NAMESPACE = "Custom/SLO"
      APPLICATIONS        = jsonencode(var.application_names)
      TARGET_GROUP_ARNS   = jsonencode([for app in var.application_names : aws_lb_target_group.apps[app].arn])
    }
  }
  
  tags = {
    Name = "${var.project_name}-slo-calculator"
  }
}

# Scheduled SLO calculation
resource "aws_cloudwatch_event_rule" "slo_calculation" {
  name                = "${var.project_name}-slo-calculation"
  description         = "Scheduled SLO calculation and reporting"
  schedule_expression = "rate(5 minutes)"
  
  tags = {
    Name = "${var.project_name}-slo-calculation"
  }
}

resource "aws_cloudwatch_event_target" "slo_calculation_target" {
  rule      = aws_cloudwatch_event_rule.slo_calculation.name
  target_id = "SLOCalculationTarget"
  arn       = aws_lambda_function.slo_calculator.arn
}

# SLO Burn Rate Alerts
resource "aws_cloudwatch_metric_alarm" "slo_burn_rate_fast" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-slo-burn-fast"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ErrorBudgetBurnRate"
  namespace           = "Custom/SLO"
  period              = "300"  # 5 minutes
  statistic           = "Average"
  threshold           = "14.4"  # 2% of monthly budget in 1 hour
  alarm_description   = "Fast burn rate detected - immediate attention required"
  alarm_actions       = [aws_sns_topic.critical_alerts.arn]
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    Application = each.key
    BurnWindow  = "1hour"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-slo-burn-fast"
    Application = each.key
    Severity    = "critical"
    SLO         = "true"
  }
}

resource "aws_cloudwatch_metric_alarm" "slo_burn_rate_slow" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-slo-burn-slow"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "6"
  metric_name         = "ErrorBudgetBurnRate"
  namespace           = "Custom/SLO"
  period              = "300"  # 5 minutes
  statistic           = "Average"
  threshold           = "1"     # Normal burn rate
  alarm_description   = "Slow burn rate detected - monitor closely"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    Application = each.key
    BurnWindow  = "6hours"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-slo-burn-slow"
    Application = each.key
    Severity    = "warning"
    SLO         = "true"
  }
}

# Availability SLI - Synthetic Health Checks
resource "aws_synthetics_canary" "availability_check" {
  for_each = toset(var.application_names)
  
  name                 = "${var.project_name}-${each.key}-availability"
  artifact_s3_location = "s3://${aws_s3_bucket.synthetics_artifacts.bucket}/canary-artifacts"
  execution_role_arn   = aws_iam_role.synthetics_execution.arn
  handler              = "apiCanaryBlueprint.handler"
  zip_file            = "synthetics-availability-${each.key}.zip"
  runtime_version      = "syn-python-selenium-1.3"
  
  schedule {
    expression = "rate(1 minute)"
  }
  
  run_config {
    timeout_in_seconds    = 60
    memory_in_mb         = 960
    active_tracing       = true
    
    environment_variables = {
      TARGET_URL = "https://${aws_lb.main.dns_name}/${each.key}/actuator/health"
    }
  }
  
  success_retention_period = 2
  failure_retention_period = 14
  
  tags = {
    Name        = "${var.project_name}-${each.key}-availability-canary"
    Application = each.key
    SLI         = "availability"
  }
}

# Latency SLI - Custom Metrics
resource "aws_cloudwatch_composite_alarm" "latency_slo_violation" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-latency-slo-violation"
  alarm_description   = "Latency SLO violation detected"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  
  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.p95_latency[each.key].alarm_name}) OR ALARM(${aws_cloudwatch_metric_alarm.p99_latency[each.key].alarm_name})"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-latency-slo"
    Application = each.key
    SLI         = "latency"
  }
}

resource "aws_cloudwatch_metric_alarm" "p95_latency" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-p95-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Average"
  threshold           = "0.5"  # 500ms
  alarm_description   = "P95 latency SLO violation"
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-p95-latency"
    Application = each.key
    Percentile  = "95"
  }
}

resource "aws_cloudwatch_metric_alarm" "p99_latency" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-p99-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "1.0"  # 1000ms
  alarm_description   = "P99 latency SLO violation"
  treat_missing_data  = "notBreaching"
  
  dimensions = {
    TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-p99-latency"
    Application = each.key
    Percentile  = "99"
  }
}

# Error Rate SLI
resource "aws_cloudwatch_metric_alarm" "error_rate_slo" {
  for_each = toset(var.application_names)
  
  alarm_name         = "${var.project_name}-${each.key}-error-rate-slo"
  alarm_description  = "Error rate SLO violation"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = "2"
  threshold          = "0.1"  # 0.1% error rate
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions        = [aws_sns_topic.alerts.arn]
  
  metric_query {
    id = "error_rate"
    
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      
      dimensions = {
        TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
      }
    }
    
    return_data = true
  }
  
  metric_query {
    id = "total_requests"
    
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      
      dimensions = {
        TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
      }
    }
    
    return_data = false
  }
  
  metric_query {
    id          = "error_percentage"
    expression  = "error_rate / total_requests * 100"
    label       = "Error Rate Percentage"
    return_data = true
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-error-rate-slo"
    Application = each.key
    SLI         = "error_rate"
  }
}

# SLO Reporting and Alerting
resource "aws_sns_topic" "slo_reports" {
  name = "${var.project_name}-slo-reports"
  
  tags = {
    Name = "${var.project_name}-slo-reports"
  }
}

# Weekly SLO Report
resource "aws_cloudwatch_event_rule" "weekly_slo_report" {
  name                = "${var.project_name}-weekly-slo-report"
  description         = "Weekly SLO compliance report"
  schedule_expression = "cron(0 9 ? * MON *)"  # Every Monday at 9 AM
  
  tags = {
    Name = "${var.project_name}-weekly-slo-report"
  }
}

resource "aws_lambda_function" "slo_reporter" {
  filename         = "slo-reporter.zip"
  function_name    = "${var.project_name}-slo-reporter"
  role            = aws_iam_role.slo_reporter.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 300
  memory_size      = 512
  
  environment {
    variables = {
      SNS_TOPIC_ARN      = aws_sns_topic.slo_reports.arn
      APPLICATIONS       = jsonencode(var.application_names)
      REPORT_BUCKET      = aws_s3_bucket.slo_reports.bucket
      CLOUDWATCH_NAMESPACE = "Custom/SLO"
    }
  }
  
  tags = {
    Name = "${var.project_name}-slo-reporter"
  }
}

resource "aws_cloudwatch_event_target" "slo_report_target" {
  rule      = aws_cloudwatch_event_rule.weekly_slo_report.name
  target_id = "SLOReportTarget"
  arn       = aws_lambda_function.slo_reporter.arn
}

# S3 bucket for SLO reports
resource "aws_s3_bucket" "slo_reports" {
  bucket = "${var.project_name}-slo-reports-${random_string.bucket_suffix.result}"
  
  tags = {
    Name = "${var.project_name}-slo-reports"
  }
}

resource "aws_s3_bucket_versioning" "slo_reports" {
  bucket = aws_s3_bucket.slo_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "slo_reports" {
  bucket = aws_s3_bucket.slo_reports.id
  
  rule {
    id     = "slo_reports_lifecycle"
    status = "Enabled"
    
    expiration {
      days = 90
    }
    
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Error Budget Tracking
resource "aws_cloudwatch_metric_alarm" "error_budget_exhausted" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-error-budget-exhausted"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ErrorBudgetRemaining"
  namespace           = "Custom/SLO"
  period              = "3600"  # 1 hour
  statistic           = "Average"
  threshold           = "10"    # 10% remaining
  alarm_description   = "Error budget nearly exhausted - deployment freeze recommended"
  alarm_actions       = [aws_sns_topic.critical_alerts.arn]
  treat_missing_data  = "breaching"
  
  dimensions = {
    Application = each.key
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-error-budget"
    Application = each.key
    Severity    = "critical"
    SLO         = "true"
  }
}

# SLO Dashboard for stakeholders
resource "aws_cloudwatch_dashboard" "slo_executive" {
  dashboard_name = "${var.project_name}-slo-executive-dashboard"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        
        properties = {
          metrics = [
            for app in var.application_names : [
              "Custom/SLO", "AvailabilitySLO", "Application", app,
              "Custom/SLO", "LatencyP95SLO", "Application", app,
              "Custom/SLO", "LatencyP99SLO", "Application", app,
              "Custom/SLO", "ErrorRateSLO", "Application", app
            ]
          ]
          view    = "singleValue"
          region  = var.aws_region
          title   = "SLO Compliance Summary"
          period  = 3600
          stat    = "Average"
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
              "Custom/SLO", "ErrorBudgetRemaining", "Application", app
            ]
          ]
          view    = "timeSeries"
          region  = var.aws_region
          title   = "Error Budget Consumption"
          period  = 3600
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-slo-executive-dashboard"
  }
}
