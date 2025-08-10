# Zero Trust Architecture Implementation
# Comprehensive security model with identity-based access controls

# Service Mesh with Istio-compatible configuration
resource "aws_ecs_service" "apps_with_envoy" {
  for_each = toset(var.application_names)
  
  name            = "${var.project_name}-${each.key}-mesh"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.apps_with_envoy[each.key].arn
  desired_count   = var.environment == "production" ? 3 : 2
  launch_type     = "FARGATE"
  
  # Service mesh configuration
  service_connect_configuration {
    enabled = true
    namespace = aws_service_discovery_private_dns_namespace.main.arn
    
    service {
      client_alias {
        port     = 8080
        dns_name = "${each.key}.mesh"
      }
      
      discovery_name = each.key
      port_name      = "app-port"
    }
    
    log_configuration {
      log_driver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service_connect[each.key].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "service-connect"
      }
    }
  }
  
  # mTLS and encryption in transit
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.service_mesh[each.key].id]
    assign_public_ip = false
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-mesh"
    Application = each.key
    ZeroTrust   = "enabled"
  }
}

# Enhanced task definitions with sidecar containers
resource "aws_ecs_task_definition" "apps_with_envoy" {
  for_each = toset(var.application_names)
  
  family                   = "${var.project_name}-${each.key}-mesh"
  requires_compatibilities = ["FARGATE"]
  network_mode            = "awsvpc"
  cpu                     = var.app_cpu
  memory                  = var.app_memory
  execution_role_arn      = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn           = aws_iam_role.ecs_task_role[each.key].arn
  
  container_definitions = jsonencode([
    {
      name  = each.key
      image = "${aws_ecr_repository.apps[each.key].repository_url}:latest"
      
      portMappings = [
        {
          containerPort = 8080
          name          = "app-port"
          protocol      = "tcp"
        }
      ]
      
      environment = [
        {
          name  = "APP_NAME"
          value = each.key
        },
        {
          name  = "ENVIRONMENT"
          value = var.environment
        },
        {
          name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
          value = "http://localhost:4317"
        },
        {
          name  = "MTLS_ENABLED"
          value = "true"
        }
      ]
      
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = aws_ssm_parameter.app_secrets[each.key].arn
        },
        {
          name      = "API_KEY"
          valueFrom = aws_secretsmanager_secret.app_api_keys[each.key].arn
        },
        {
          name      = "TLS_CERT"
          valueFrom = aws_secretsmanager_secret.service_certs[each.key].arn
        },
        {
          name      = "TLS_KEY"
          valueFrom = aws_secretsmanager_secret.service_keys[each.key].arn
        }
      ]
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.apps[each.key].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
      
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/actuator/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      
      dependsOn = [
        {
          containerName = "envoy-proxy"
          condition     = "HEALTHY"
        },
        {
          containerName = "otel-collector"
          condition     = "HEALTHY"
        }
      ]
    },
    {
      name  = "envoy-proxy"
      image = "envoyproxy/envoy:v1.27-latest"
      
      portMappings = [
        {
          containerPort = 15000  # Envoy admin
          protocol      = "tcp"
        },
        {
          containerPort = 15001  # Envoy outbound
          protocol      = "tcp"
        }
      ]
      
      environment = [
        {
          name  = "SERVICE_NAME"
          value = each.key
        },
        {
          name  = "ENVOY_UID"
          value = "1337"
        }
      ]
      
      mountPoints = [
        {
          sourceVolume  = "envoy-config"
          containerPath = "/etc/envoy"
          readOnly      = true
        }
      ]
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.envoy[each.key].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "envoy"
        }
      }
      
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:15000/ready || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      
      essential = true
    },
    {
      name  = "otel-collector"
      image = "otel/opentelemetry-collector-contrib:latest"
      
      portMappings = [
        {
          containerPort = 4317  # OTLP gRPC
          protocol      = "tcp"
        },
        {
          containerPort = 4318  # OTLP HTTP
          protocol      = "tcp"
        }
      ]
      
      environment = [
        {
          name  = "AWS_REGION"
          value = var.aws_region
        }
      ]
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.otel[each.key].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "otel"
        }
      }
      
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:13133/ || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      
      essential = false
    }
  ])
  
  volume {
    name = "envoy-config"
    
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.envoy_config.id
      root_directory = "/"
    }
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-mesh-task"
    Application = each.key
    ZeroTrust   = "enabled"
  }
}

# Enhanced security groups with micro-segmentation
resource "aws_security_group" "service_mesh" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-mesh-sg"
  description = "Security group for ${each.key} service mesh"
  vpc_id      = aws_vpc.main.id
  
  # Inbound rules - application port
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Application traffic from ALB"
  }
  
  # Inbound rules - Envoy admin (restricted)
  ingress {
    from_port   = 15000
    to_port     = 15000
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Envoy admin interface"
  }
  
  # Service-to-service communication (mTLS)
  dynamic "ingress" {
    for_each = toset([for app in var.application_names : app if app != each.key])
    content {
      from_port                = 8080
      to_port                  = 8080
      protocol                 = "tcp"
      source_security_group_id = aws_security_group.service_mesh[ingress.value].id
      description              = "mTLS traffic from ${ingress.value}"
    }
  }
  
  # Outbound rules - all traffic (controlled by service mesh)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-mesh-sg"
    Application = each.key
    ZeroTrust   = "enabled"
  }
}

# Certificate management for mTLS
resource "aws_secretsmanager_secret" "service_certs" {
  for_each = toset(var.application_names)
  
  name                    = "${var.project_name}/${each.key}/tls-cert"
  description             = "TLS certificate for ${each.key} service"
  recovery_window_in_days = 0  # Immediate deletion for development
  
  tags = {
    Name        = "${var.project_name}-${each.key}-cert"
    Application = each.key
    SecretType  = "certificate"
  }
}

resource "aws_secretsmanager_secret" "service_keys" {
  for_each = toset(var.application_names)
  
  name                    = "${var.project_name}/${each.key}/tls-key"
  description             = "TLS private key for ${each.key} service"
  recovery_window_in_days = 0  # Immediate deletion for development
  
  tags = {
    Name        = "${var.project_name}-${each.key}-key"
    Application = each.key
    SecretType  = "private-key"
  }
}

# Certificate Authority for internal mTLS
resource "aws_secretsmanager_secret" "internal_ca" {
  name                    = "${var.project_name}/internal-ca"
  description             = "Internal Certificate Authority for service mesh"
  recovery_window_in_days = 7
  
  tags = {
    Name       = "${var.project_name}-internal-ca"
    SecretType = "ca-certificate"
  }
}

# Enhanced IAM roles with fine-grained permissions
resource "aws_iam_role" "ecs_task_role" {
  for_each = toset(var.application_names)
  
  name = "${var.project_name}-${each.key}-task-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      }
    ]
  })
  
  tags = {
    Name        = "${var.project_name}-${each.key}-task-role"
    Application = each.key
    ZeroTrust   = "enabled"
  }
}

# Application-specific IAM policies
resource "aws_iam_policy" "app_permissions" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-permissions"
  description = "Application-specific permissions for ${each.key}"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.app_api_keys[each.key].arn,
          aws_secretsmanager_secret.service_certs[each.key].arn,
          aws_secretsmanager_secret.service_keys[each.key].arn,
          aws_secretsmanager_secret.internal_ca.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          aws_ssm_parameter.app_secrets[each.key].arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [
          aws_kms_key.secrets.arn
        ]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.apps[each.key].arn}:*",
          "${aws_cloudwatch_log_group.envoy[each.key].arn}:*",
          "${aws_cloudwatch_log_group.otel[each.key].arn}:*"
        ]
      }
    ]
  })
  
  tags = {
    Name        = "${var.project_name}-${each.key}-permissions"
    Application = each.key
  }
}

resource "aws_iam_role_policy_attachment" "app_permissions" {
  for_each = toset(var.application_names)
  
  role       = aws_iam_role.ecs_task_role[each.key].name
  policy_arn = aws_iam_policy.app_permissions[each.key].arn
}

# Network policies using AWS VPC Lattice (if available)
resource "aws_vpclattice_service_network" "main" {
  name      = "${var.project_name}-service-network"
  auth_type = "AWS_IAM"
  
  tags = {
    Name      = "${var.project_name}-service-network"
    ZeroTrust = "enabled"
  }
}

resource "aws_vpclattice_service" "apps" {
  for_each = toset(var.application_names)
  
  name               = "${var.project_name}-${each.key}-service"
  auth_type          = "AWS_IAM"
  certificate_arn    = aws_acm_certificate.service_mesh[each.key].arn
  custom_domain_name = "${each.key}.${var.project_name}.internal"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-service"
    Application = each.key
    ZeroTrust   = "enabled"
  }
}

# Service mesh certificates
resource "aws_acm_certificate" "service_mesh" {
  for_each = toset(var.application_names)
  
  domain_name       = "${each.key}.${var.project_name}.internal"
  validation_method = "DNS"
  
  subject_alternative_names = [
    "*.${each.key}.${var.project_name}.internal"
  ]
  
  lifecycle {
    create_before_destroy = true
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-mesh-cert"
    Application = each.key
    ZeroTrust   = "enabled"
  }
}

# Identity-based access control
resource "aws_iam_policy" "service_to_service_access" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-service-access"
  description = "Service-to-service access policy for ${each.key}"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "vpc-lattice:Invoke"
        ]
        Resource = [
          for target_app in var.application_names :
          aws_vpclattice_service.apps[target_app].arn
          if target_app != each.key && contains(var.service_dependencies[each.key], target_app)
        ]
        Condition = {
          StringEquals = {
            "vpc-lattice:ServiceNetworkArn" = aws_vpclattice_service_network.main.arn
          }
        }
      }
    ]
  })
  
  tags = {
    Name        = "${var.project_name}-${each.key}-service-access"
    Application = each.key
  }
}

# EFS for shared configuration
resource "aws_efs_file_system" "envoy_config" {
  creation_token   = "${var.project_name}-envoy-config"
  performance_mode = "generalPurpose"
  throughput_mode  = "provisioned"
  provisioned_throughput_in_mibps = 100
  
  encrypted = true
  kms_key_id = aws_kms_key.efs.arn
  
  tags = {
    Name = "${var.project_name}-envoy-config"
  }
}

resource "aws_efs_mount_target" "envoy_config" {
  for_each = toset(data.aws_availability_zones.available.names)
  
  file_system_id  = aws_efs_file_system.envoy_config.id
  subnet_id       = aws_subnet.private[index(data.aws_availability_zones.available.names, each.key)].id
  security_groups = [aws_security_group.efs.id]
}

# Enhanced CloudWatch log groups
resource "aws_cloudwatch_log_group" "service_connect" {
  for_each = toset(var.application_names)
  
  name              = "/aws/ecs/${var.project_name}/${each.key}/service-connect"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.logs.arn
  
  tags = {
    Name        = "${var.project_name}-${each.key}-service-connect-logs"
    Application = each.key
  }
}

resource "aws_cloudwatch_log_group" "envoy" {
  for_each = toset(var.application_names)
  
  name              = "/aws/ecs/${var.project_name}/${each.key}/envoy"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.logs.arn
  
  tags = {
    Name        = "${var.project_name}-${each.key}-envoy-logs"
    Application = each.key
  }
}

resource "aws_cloudwatch_log_group" "otel" {
  for_each = toset(var.application_names)
  
  name              = "/aws/ecs/${var.project_name}/${each.key}/otel"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.logs.arn
  
  tags = {
    Name        = "${var.project_name}-${each.key}-otel-logs"
    Application = each.key
  }
}

# Zero Trust monitoring and alerting
resource "aws_cloudwatch_metric_alarm" "unauthorized_access" {
  for_each = toset(var.application_names)
  
  alarm_name          = "${var.project_name}-${each.key}-unauthorized-access"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "UnauthorizedApiCalls"
  namespace           = "AWS/VPCLattice"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "Unauthorized access attempts detected"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
  
  dimensions = {
    ServiceName = aws_vpclattice_service.apps[each.key].name
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-unauthorized-access"
    Application = each.key
    Security    = "critical"
  }
}

# Security alerts topic
resource "aws_sns_topic" "security_alerts" {
  name = "${var.project_name}-security-alerts"
  
  tags = {
    Name = "${var.project_name}-security-alerts"
  }
}
