# ECS Services and Task Definitions for all 10 applications

# IAM Role for ECS Tasks
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-task-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-ecs-task-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional IAM policy for ECS tasks to access other AWS services
resource "aws_iam_role_policy" "ecs_task_execution_additional" {
  name = "${var.project_name}-ecs-task-execution-additional"
  role = aws_iam_role.ecs_task_execution_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "ssm:GetParameters",
          "ssm:GetParameter",
          "kms:Decrypt",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Role for ECS Tasks (application role)
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-ecs-task-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-ecs-task-role"
  }
}

# CloudWatch Log Groups for each application
resource "aws_cloudwatch_log_group" "app_logs" {
  for_each = toset(var.application_names)
  
  name              = "/aws/ecs/${var.project_name}/${each.key}"
  retention_in_days = var.log_retention_days
  
  tags = {
    Name        = "${var.project_name}-${each.key}-logs"
    Application = each.key
  }
}

# ECS Task Definitions for each application
resource "aws_ecs_task_definition" "apps" {
  for_each = toset(var.application_names)
  
  family                   = "${var.project_name}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ecs_task_cpu[each.key]
  memory                   = var.ecs_task_memory[each.key]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn           = aws_iam_role.ecs_task_role.arn
  
  container_definitions = jsonencode([
    {
      name  = each.key
      image = "${aws_ecr_repository.apps[each.key].repository_url}:latest"
      
      portMappings = [
        {
          containerPort = var.application_ports[each.key]
          protocol      = "tcp"
        }
      ]
      
      essential = true
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app_logs[each.key].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      
      environment = [
        {
          name  = "NODE_ENV"
          value = var.environment
        },
        {
          name  = "PORT"
          value = tostring(var.application_ports[each.key])
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        }
      ]
      
      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.database_urls[each.key].arn
        }
      ]
      
      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl -f http://localhost:${var.application_ports[each.key]}${var.health_check_paths[each.key]} || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      
      ulimits = [
        {
          name      = "nofile"
          softLimit = 65536
          hardLimit = 65536
        }
      ]
    }
  ])
  
  tags = {
    Name        = "${var.project_name}-${each.key}-task"
    Application = each.key
  }
}

# Target Groups for each application
resource "aws_lb_target_group" "apps" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-tg"
  port        = var.application_ports[each.key]
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = var.health_check_paths[each.key]
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }
  
  deregistration_delay = 30
  
  tags = {
    Name        = "${var.project_name}-${each.key}-tg"
    Application = each.key
  }
}

# ALB Listener Rules for each application
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type = "fixed-response"
    
    fixed_response {
      content_type = "text/plain"
      message_body = "Service not found"
      status_code  = "404"
    }
  }
  
  tags = {
    Name = "${var.project_name}-listener"
  }
}

resource "aws_lb_listener_rule" "apps" {
  for_each = toset(var.application_names)
  
  listener_arn = aws_lb_listener.main.arn
  priority     = index(var.application_names, each.key) + 100
  
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apps[each.key].arn
  }
  
  condition {
    path_pattern {
      values = ["/${each.key}/*"]
    }
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-rule"
    Application = each.key
  }
}

# ECS Services for each application
resource "aws_ecs_service" "apps" {
  for_each = toset(var.application_names)
  
  name            = "${var.project_name}-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.apps[each.key].arn
  desired_count   = var.desired_count[each.key]
  launch_type     = "FARGATE"
  
  platform_version = "LATEST"
  
  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets         = aws_subnet.private[*].id
    assign_public_ip = false
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.apps[each.key].arn
    container_name   = each.key
    container_port   = var.application_ports[each.key]
  }
  
  deployment_configuration {
    maximum_percent         = 200
    minimum_healthy_percent = 50
    
    deployment_circuit_breaker {
      enable   = true
      rollback = true
    }
  }
  
  service_registries {
    registry_arn = aws_service_discovery_service.apps[each.key].arn
  }
  
  enable_execute_command = true
  
  depends_on = [
    aws_lb_listener_rule.apps,
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy
  ]
  
  tags = {
    Name        = "${var.project_name}-${each.key}-service"
    Application = each.key
  }
}

# Service Discovery
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.project_name}.local"
  vpc  = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-namespace"
  }
}

resource "aws_service_discovery_service" "apps" {
  for_each = toset(var.application_names)
  
  name = each.key
  
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    
    dns_records {
      ttl  = 10
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

# Auto Scaling for ECS Services
resource "aws_appautoscaling_target" "apps" {
  for_each = toset(var.application_names)
  
  max_capacity       = var.max_capacity[each.key]
  min_capacity       = var.min_capacity[each.key]
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.apps[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-autoscaling"
    Application = each.key
  }
}

# Auto Scaling Policies - CPU
resource "aws_appautoscaling_policy" "cpu_scaling" {
  for_each = toset(var.application_names)
  
  name               = "${var.project_name}-${each.key}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.apps[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.apps[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.apps[each.key].service_namespace
  
  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    
    scale_out_cooldown = 300
    scale_in_cooldown  = 300
  }
}

# Auto Scaling Policies - Memory
resource "aws_appautoscaling_policy" "memory_scaling" {
  for_each = toset(var.application_names)
  
  name               = "${var.project_name}-${each.key}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.apps[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.apps[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.apps[each.key].service_namespace
  
  target_tracking_scaling_policy_configuration {
    target_value = 80.0
    
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    
    scale_out_cooldown = 300
    scale_in_cooldown  = 300
  }
}

# Secrets for database connections
resource "aws_secretsmanager_secret" "database_urls" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}/${each.key}/database-url"
  description = "Database connection string for ${each.key}"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-db-secret"
    Application = each.key
  }
}

resource "aws_secretsmanager_secret_version" "database_urls" {
  for_each = toset(var.application_names)
  
  secret_id = aws_secretsmanager_secret.database_urls[each.key].id
  secret_string = jsonencode({
    url = "postgresql://admin:changeme@${aws_db_instance.apps[each.key].endpoint}:5432/${each.key}_db"
  })
}

# RDS Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  
  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# RDS Security Group
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }
  
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }
  
  ingress {
    from_port       = 1521
    to_port         = 1521
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }
  
  ingress {
    from_port       = 1433
    to_port         = 1433
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# RDS Instances for each application
resource "aws_db_instance" "apps" {
  for_each = toset(var.application_names)
  
  identifier = "${var.project_name}-${each.key}-db"
  
  engine         = var.database_engines[each.key]
  engine_version = "13.7"
  instance_class = var.database_instance_classes[each.key]
  
  allocated_storage     = 100
  max_allocated_storage = 1000
  storage_type          = "gp2"
  storage_encrypted     = true
  
  db_name  = "${replace(each.key, "-", "_")}_db"
  username = "admin"
  password = "changeme123!"
  
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  
  backup_retention_period = var.backup_retention_days
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  skip_final_snapshot = true
  deletion_protection = false
  
  performance_insights_enabled = true
  monitoring_interval         = 60
  monitoring_role_arn        = aws_iam_role.rds_monitoring.arn
  
  tags = {
    Name        = "${var.project_name}-${each.key}-db"
    Application = each.key
  }
}

# RDS Enhanced Monitoring Role
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
