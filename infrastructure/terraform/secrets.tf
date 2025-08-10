# Secrets Management Configuration for ECS Workload Modernization
# Enterprise-grade secrets management with AWS Systems Manager and Secrets Manager

# AWS Systems Manager Parameter Store for non-sensitive configuration
resource "aws_ssm_parameter" "github_token" {
  name        = "/ecs-modernization/github-token"
  description = "GitHub personal access token for CodePipeline"
  type        = "SecureString"
  value       = "PLACEHOLDER_VALUE"  # This should be set manually or via CLI
  key_id      = aws_kms_key.secrets.arn
  
  lifecycle {
    ignore_changes = [value]
  }
  
  tags = {
    Name        = "github-token"
    Environment = var.environment
    SecretType  = "api-token"
  }
}

resource "aws_ssm_parameter" "sonarqube_host_url" {
  name        = "/ecs-modernization/sonarqube-host-url"
  description = "SonarQube server URL for code quality analysis"
  type        = "String"
  value       = "https://sonar.company.com"
  
  tags = {
    Name        = "sonarqube-host-url"
    Environment = var.environment
    SecretType  = "configuration"
  }
}

resource "aws_ssm_parameter" "snyk_org_id" {
  name        = "/ecs-modernization/snyk-org-id"
  description = "Snyk organization ID for vulnerability scanning"
  type        = "String"
  value       = "your-snyk-org-id"
  
  tags = {
    Name        = "snyk-org-id"
    Environment = var.environment
    SecretType  = "configuration"
  }
}

resource "aws_ssm_parameter" "aws_account_id" {
  name        = "/ecs-modernization/aws-account-id"
  description = "AWS Account ID for the deployment"
  type        = "String"
  value       = data.aws_caller_identity.current.account_id
  
  tags = {
    Name        = "aws-account-id"
    Environment = var.environment
    SecretType  = "configuration"
  }
}

# KMS Key for secrets encryption
resource "aws_kms_key" "secrets" {
  description             = "KMS key for secrets encryption"
  deletion_window_in_days = 7
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow AWS Services"
        Effect = "Allow"
        Principal = {
          Service = [
            "secretsmanager.amazonaws.com",
            "ssm.amazonaws.com",
            "codebuild.amazonaws.com",
            "lambda.amazonaws.com"
          ]
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-secrets-kms"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# AWS Secrets Manager for sensitive application secrets
resource "aws_secretsmanager_secret" "sonarqube_token" {
  name        = "ecs-modernization/sonarqube"
  description = "SonarQube authentication token"
  kms_key_id  = aws_kms_key.secrets.arn
  
  replica {
    region = "us-west-2"
  }
  
  tags = {
    Name        = "sonarqube-credentials"
    Environment = var.environment
    SecretType  = "api-token"
  }
}

resource "aws_secretsmanager_secret_version" "sonarqube_token" {
  secret_id = aws_secretsmanager_secret.sonarqube_token.id
  secret_string = jsonencode({
    token = "PLACEHOLDER_TOKEN"  # This should be set manually
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "snyk_token" {
  name        = "ecs-modernization/snyk"
  description = "Snyk authentication token for vulnerability scanning"
  kms_key_id  = aws_kms_key.secrets.arn
  
  replica {
    region = "us-west-2"
  }
  
  tags = {
    Name        = "snyk-credentials"
    Environment = var.environment
    SecretType  = "api-token"
  }
}

resource "aws_secretsmanager_secret_version" "snyk_token" {
  secret_id = aws_secretsmanager_secret.snyk_token.id
  secret_string = jsonencode({
    token = "PLACEHOLDER_TOKEN"  # This should be set manually
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "veracode_credentials" {
  name        = "ecs-modernization/veracode"
  description = "Veracode API credentials for security scanning"
  kms_key_id  = aws_kms_key.secrets.arn
  
  tags = {
    Name        = "veracode-credentials"
    Environment = var.environment
    SecretType  = "api-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "veracode_credentials" {
  secret_id = aws_secretsmanager_secret.veracode_credentials.id
  secret_string = jsonencode({
    api_id  = "PLACEHOLDER_API_ID"
    api_key = "PLACEHOLDER_API_KEY"
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "docker_registry" {
  name        = "ecs-modernization/docker-registry"
  description = "Docker registry credentials for private repositories"
  kms_key_id  = aws_kms_key.secrets.arn
  
  tags = {
    Name        = "docker-registry-credentials"
    Environment = var.environment
    SecretType  = "registry-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "docker_registry" {
  secret_id = aws_secretsmanager_secret.docker_registry.id
  secret_string = jsonencode({
    username = "aws"
    password = "PLACEHOLDER_PASSWORD"  # ECR token will be generated dynamically
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Application-specific database credentials
resource "aws_secretsmanager_secret" "app_database_credentials" {
  for_each = toset(var.application_names)
  
  name        = "ecs-modernization/${each.key}/database"
  description = "Database credentials for ${each.key} application"
  kms_key_id  = aws_kms_key.secrets.arn
  
  replica {
    region = "us-west-2"
  }
  
  tags = {
    Name        = "${each.key}-database-credentials"
    Application = each.key
    Environment = var.environment
    SecretType  = "database-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "app_database_credentials" {
  for_each = toset(var.application_names)
  
  secret_id = aws_secretsmanager_secret.app_database_credentials[each.key].id
  secret_string = jsonencode({
    host     = aws_db_instance.apps[each.key].endpoint
    port     = aws_db_instance.apps[each.key].port
    dbname   = aws_db_instance.apps[each.key].db_name
    username = aws_db_instance.apps[each.key].username
    password = aws_db_instance.apps[each.key].password
    engine   = aws_db_instance.apps[each.key].engine
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Monitoring and observability secrets
resource "aws_secretsmanager_secret" "datadog_credentials" {
  name        = "ecs-modernization/datadog"
  description = "Datadog API credentials for monitoring integration"
  kms_key_id  = aws_kms_key.secrets.arn
  
  tags = {
    Name        = "datadog-credentials"
    Environment = var.environment
    SecretType  = "monitoring-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "datadog_credentials" {
  secret_id = aws_secretsmanager_secret.datadog_credentials.id
  secret_string = jsonencode({
    api_key         = "PLACEHOLDER_API_KEY"
    application_key = "PLACEHOLDER_APP_KEY"
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "newrelic_credentials" {
  name        = "ecs-modernization/newrelic"
  description = "New Relic API credentials for APM integration"
  kms_key_id  = aws_kms_key.secrets.arn
  
  tags = {
    Name        = "newrelic-credentials"
    Environment = var.environment
    SecretType  = "monitoring-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "newrelic_credentials" {
  secret_id = aws_secretsmanager_secret.newrelic_credentials.id
  secret_string = jsonencode({
    api_key        = "PLACEHOLDER_API_KEY"
    application_id = "PLACEHOLDER_APP_ID"
    license_key    = "PLACEHOLDER_LICENSE_KEY"
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# JWT and API secrets for applications
resource "aws_secretsmanager_secret" "app_api_secrets" {
  for_each = toset(var.application_names)
  
  name        = "ecs-modernization/${each.key}/api-secrets"
  description = "API secrets and JWT keys for ${each.key} application"
  kms_key_id  = aws_kms_key.secrets.arn
  
  tags = {
    Name        = "${each.key}-api-secrets"
    Application = each.key
    Environment = var.environment
    SecretType  = "application-secrets"
  }
}

resource "aws_secretsmanager_secret_version" "app_api_secrets" {
  for_each = toset(var.application_names)
  
  secret_id = aws_secretsmanager_secret.app_api_secrets[each.key].id
  secret_string = jsonencode({
    jwt_secret    = "PLACEHOLDER_JWT_SECRET"
    api_key       = "PLACEHOLDER_API_KEY"
    encrypt_key   = "PLACEHOLDER_ENCRYPT_KEY"
    webhook_secret = "PLACEHOLDER_WEBHOOK_SECRET"
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# IAM policy for applications to access their secrets
resource "aws_iam_policy" "app_secrets_access" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-secrets-access"
  description = "Policy for ${each.key} to access its secrets"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.app_database_credentials[each.key].arn,
          aws_secretsmanager_secret.app_api_secrets[each.key].arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ecs-modernization/${each.key}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.secrets.arn
        ]
      }
    ]
  })
  
  tags = {
    Name        = "${var.project_name}-${each.key}-secrets-access"
    Application = each.key
  }
}

# Attach secrets access policy to ECS task role
resource "aws_iam_role_policy_attachment" "app_secrets_access" {
  for_each = toset(var.application_names)
  
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.app_secrets_access[each.key].arn
}

# Lambda function for secrets rotation
resource "aws_lambda_function" "secrets_rotation" {
  filename         = "secrets-rotation-lambda.zip"
  function_name    = "${var.project_name}-secrets-rotation"
  role            = aws_iam_role.lambda_secrets_rotation.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 300
  
  environment {
    variables = {
      KMS_KEY_ID = aws_kms_key.secrets.key_id
    }
  }
  
  tags = {
    Name = "${var.project_name}-secrets-rotation"
  }
}

# IAM Role for secrets rotation Lambda
resource "aws_iam_role" "lambda_secrets_rotation" {
  name = "${var.project_name}-lambda-secrets-rotation-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-lambda-secrets-rotation-role"
  }
}

resource "aws_iam_role_policy" "lambda_secrets_rotation" {
  name = "${var.project_name}-lambda-secrets-rotation-policy"
  role = aws_iam_role.lambda_secrets_rotation.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.secrets.arn
        ]
      }
    ]
  })
}

# CloudWatch Events for automated secrets rotation
resource "aws_cloudwatch_event_rule" "secrets_rotation" {
  name                = "${var.project_name}-secrets-rotation"
  description         = "Trigger secrets rotation every 90 days"
  schedule_expression = "rate(90 days)"
  
  tags = {
    Name = "${var.project_name}-secrets-rotation"
  }
}

resource "aws_cloudwatch_event_target" "secrets_rotation" {
  rule      = aws_cloudwatch_event_rule.secrets_rotation.name
  target_id = "SecretsRotationTarget"
  arn       = aws_lambda_function.secrets_rotation.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.secrets_rotation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.secrets_rotation.arn
}
