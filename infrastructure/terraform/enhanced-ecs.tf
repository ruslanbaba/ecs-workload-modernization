# Multi-AZ ECS Deployment with Advanced Auto-Scaling
# Enhanced infrastructure for high availability and resilience

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Enhanced ECS Cluster with multi-AZ configuration
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
  
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  
  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.ecs.arn
      logging    = "OVERRIDE"
      
      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }
  
  tags = {
    Name = "${var.project_name}-cluster"
    HighAvailability = "true"
  }
}

# Enhanced ECS Services with multi-AZ deployment
resource "aws_ecs_service" "apps" {
  for_each = toset(var.application_names)
  
  name            = "${var.project_name}-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.apps[each.key].arn
  desired_count   = var.environment == "production" ? 3 : 2
  launch_type     = "FARGATE"
  
  # Platform version for enhanced security and performance
  platform_version = "1.4.0"
  
  # Network configuration with multi-AZ subnets
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }
  
  # Load balancer configuration
  load_balancer {
    target_group_arn = aws_lb_target_group.apps[each.key].arn
    container_name   = each.key
    container_port   = 8080
  }
  
  # Service discovery
  service_registries {
    registry_arn = aws_service_discovery_service.apps[each.key].arn
  }
  
  # Deployment configuration for zero-downtime deployments
  deployment_configuration {
    maximum_percent         = 200
    minimum_healthy_percent = 100
    
    deployment_circuit_breaker {
      enable   = true
      rollback = true
    }
  }
  
  # Auto-scaling configuration
  lifecycle {
    ignore_changes = [desired_count]
  }
  
  depends_on = [
    aws_lb_listener.main,
    aws_iam_role_policy_attachment.ecs_task_execution_role
  ]
  
  tags = {
    Name        = "${var.project_name}-${each.key}"
    Application = each.key
    Environment = var.environment
  }
}

# Application Auto Scaling Target
resource "aws_appautoscaling_target" "ecs_target" {
  for_each = toset(var.application_names)
  
  max_capacity       = var.environment == "production" ? 20 : 10
  min_capacity       = var.environment == "production" ? 3 : 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.apps[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-scaling-target"
    Application = each.key
  }
}

# CPU-based Auto Scaling Policy
resource "aws_appautoscaling_policy" "ecs_cpu_policy" {
  for_each = toset(var.application_names)
  
  name               = "${var.project_name}-${each.key}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target[each.key].service_namespace
  
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Memory-based Auto Scaling Policy
resource "aws_appautoscaling_policy" "ecs_memory_policy" {
  for_each = toset(var.application_names)
  
  name               = "${var.project_name}-${each.key}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target[each.key].service_namespace
  
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Custom metrics-based Auto Scaling (Request Count)
resource "aws_appautoscaling_policy" "ecs_request_count_policy" {
  for_each = toset(var.application_names)
  
  name               = "${var.project_name}-${each.key}-request-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target[each.key].service_namespace
  
  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      metric_name = "RequestCountPerTarget"
      namespace   = "AWS/ApplicationELB"
      statistic   = "Sum"
      
      dimensions = {
        TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
      }
    }
    target_value       = 1000.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Enhanced Application Load Balancer with multi-AZ
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = var.environment == "production" ? true : false
  enable_http2              = true
  enable_cross_zone_load_balancing = true
  
  # Access logs for monitoring
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb-access-logs"
    enabled = true
  }
  
  tags = {
    Name        = "${var.project_name}-alb"
    Environment = var.environment
  }
}

# Enhanced Health Checks
resource "aws_lb_target_group" "apps" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  
  # Advanced health check configuration
  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 15
    matcher             = "200,301,302"
    path                = "/actuator/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }
  
  # Stickiness for session-aware applications
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = false  # Enable if needed
  }
  
  # Deregistration delay optimization
  deregistration_delay = 30
  
  tags = {
    Name        = "${var.project_name}-${each.key}-tg"
    Application = each.key
  }
}

# Service Discovery for service-to-service communication
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project_name}.local"
  description = "Private DNS namespace for ECS services"
  vpc         = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-service-discovery"
  }
}

resource "aws_service_discovery_service" "apps" {
  for_each = toset(var.application_names)
  
  name = each.key
  
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    
    dns_records {
      ttl  = 60
      type = "A"
    }
    
    routing_policy = "MULTIVALUE"
  }
  
  health_check_grace_period_seconds = 30
  
  tags = {
    Name        = "${var.project_name}-${each.key}-discovery"
    Application = each.key
  }
}

# Enhanced CloudWatch Alarms for proactive monitoring
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "85"
  alarm_description   = "This metric monitors ECS service CPU utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    ServiceName = aws_ecs_service.apps[each.key].name
    ClusterName = aws_ecs_cluster.main.name
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-cpu-alarm"
    Application = each.key
    Severity    = "high"
  }
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "90"
  alarm_description   = "This metric monitors ECS service memory utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    ServiceName = aws_ecs_service.apps[each.key].name
    ClusterName = aws_ecs_cluster.main.name
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-memory-alarm"
    Application = each.key
    Severity    = "high"
  }
}

# Application-level health monitoring
resource "aws_cloudwatch_metric_alarm" "target_response_time" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1.0"  # 1 second
  alarm_description   = "This metric monitors application response time"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  
  dimensions = {
    TargetGroup = aws_lb_target_group.apps[each.key].arn_suffix
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-response-time-alarm"
    Application = each.key
    Severity    = "medium"
  }
}

# Circuit breaker pattern using Lambda and API Gateway
resource "aws_lambda_function" "circuit_breaker" {
  for_each = toset(var.application_names)
  
  filename         = "circuit-breaker-${each.key}.zip"
  function_name    = "${var.project_name}-${each.key}-circuit-breaker"
  role            = aws_iam_role.circuit_breaker_lambda.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 30
  
  environment {
    variables = {
      SERVICE_ENDPOINT = "http://${each.key}.${aws_service_discovery_private_dns_namespace.main.name}:8080"
      FAILURE_THRESHOLD = "5"
      RECOVERY_TIMEOUT = "60"
      TIMEOUT = "30"
    }
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-circuit-breaker"
    Application = each.key
  }
}

# Chaos Engineering Lambda for resilience testing
resource "aws_lambda_function" "chaos_engineering" {
  filename         = "chaos-engineering.zip"
  function_name    = "${var.project_name}-chaos-engineering"
  role            = aws_iam_role.chaos_lambda.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 300
  
  environment {
    variables = {
      CLUSTER_NAME = aws_ecs_cluster.main.name
      CHAOS_MODE   = var.environment == "production" ? "safe" : "aggressive"
    }
  }
  
  tags = {
    Name = "${var.project_name}-chaos-engineering"
  }
}

# Scheduled chaos experiments
resource "aws_cloudwatch_event_rule" "chaos_schedule" {
  name                = "${var.project_name}-chaos-schedule"
  description         = "Scheduled chaos engineering experiments"
  schedule_expression = "cron(0 10 * * MON *)"  # Every Monday at 10 AM
  
  tags = {
    Name = "${var.project_name}-chaos-schedule"
  }
}

resource "aws_cloudwatch_event_target" "chaos_target" {
  rule      = aws_cloudwatch_event_rule.chaos_schedule.name
  target_id = "ChaosEngineeringTarget"
  arn       = aws_lambda_function.chaos_engineering.arn
}

# Enhanced logging with structured logs
resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/aws/ecs/${var.project_name}/exec"
  retention_in_days = 30
  
  tags = {
    Name = "${var.project_name}-ecs-exec-logs"
  }
}

# Cross-AZ backup strategy
resource "aws_backup_vault" "main" {
  name        = "${var.project_name}-backup-vault"
  kms_key_arn = aws_kms_key.backup.arn
  
  tags = {
    Name = "${var.project_name}-backup-vault"
  }
}

resource "aws_backup_plan" "main" {
  name = "${var.project_name}-backup-plan"
  
  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 2 * * ? *)"  # Daily at 2 AM
    
    lifecycle {
      cold_storage_after = 30
      delete_after       = 365
    }
    
    recovery_point_tags = {
      Environment = var.environment
      Automated   = "true"
    }
  }
  
  tags = {
    Name = "${var.project_name}-backup-plan"
  }
}
