# Security Configuration for ECS Workload Modernization
# Enterprise-grade security controls and compliance

# AWS WAF Configuration
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project_name}-web-acl"
  scope = "REGIONAL"
  
  default_action {
    allow {}
  }
  
  # Rate limiting rule
  rule {
    name     = "RateLimitRule"
    priority = 1
    
    action {
      block {}
    }
    
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRule"
      sampled_requests_enabled   = true
    }
  }
  
  # AWS Managed Rules - Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2
    
    override_action {
      none {}
    }
    
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }
  
  # SQL Injection Protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3
    
    override_action {
      none {}
    }
    
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }
  
  # OWASP Top 10 Protection
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 4
    
    override_action {
      none {}
    }
    
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputsMetric"
      sampled_requests_enabled   = true
    }
  }
  
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}WebAcl"
    sampled_requests_enabled   = true
  }
  
  tags = {
    Name = "${var.project_name}-web-acl"
  }
}

# Associate WAF with ALB
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# GuardDuty for threat detection
resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  
  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }
  
  tags = {
    Name = "${var.project_name}-guardduty"
  }
}

# Security Hub for centralized security findings
resource "aws_securityhub_account" "main" {
  enable_default_standards = true
}

# Config Rules for compliance monitoring
resource "aws_config_configuration_recorder" "main" {
  name     = "${var.project_name}-config-recorder"
  role_arn = aws_iam_role.config.arn
  
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.project_name}-config-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config.id
  
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_s3_bucket" "config" {
  bucket        = "${var.project_name}-config-${random_string.bucket_suffix.result}"
  force_destroy = true
  
  tags = {
    Name = "${var.project_name}-config"
  }
}

resource "aws_iam_role" "config" {
  name = "${var.project_name}-config-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-config-role"
  }
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/ConfigRole"
}

# VPC Flow Logs for network monitoring
resource "aws_flow_log" "vpc" {
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_log.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-vpc-flow-log"
  }
}

resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  name              = "/aws/vpc/${var.project_name}/flowlogs"
  retention_in_days = var.log_retention_days
  
  tags = {
    Name = "${var.project_name}-vpc-flow-log"
  }
}

resource "aws_iam_role" "flow_log" {
  name = "${var.project_name}-flow-log-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-flow-log-role"
  }
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.project_name}-flow-log-policy"
  role = aws_iam_role.flow_log.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# AWS Inspector for vulnerability assessments
resource "aws_inspector_assessment_target" "main" {
  name = "${var.project_name}-assessment-target"
}

resource "aws_inspector_assessment_template" "main" {
  name       = "${var.project_name}-assessment-template"
  target_arn = aws_inspector_assessment_target.main.arn
  duration   = 3600
  
  rules_package_arns = [
    "arn:aws:inspector:${var.aws_region}:316112463485:rulespackage/0-R01qwB5Q",  # Security Best Practices
    "arn:aws:inspector:${var.aws_region}:316112463485:rulespackage/0-gEjTy7T7",  # Runtime Behavior Analysis
    "arn:aws:inspector:${var.aws_region}:316112463485:rulespackage/0-rExsr2X8",  # Network Reachability
    "arn:aws:inspector:${var.aws_region}:316112463485:rulespackage/0-R3ux3Xz5"   # Common Vulnerabilities and Exposures
  ]
  
  tags = {
    Name = "${var.project_name}-assessment-template"
  }
}

# Secrets Manager for application secrets
resource "aws_secretsmanager_secret" "api_keys" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}/${each.key}/api-keys"
  description = "API keys and secrets for ${each.key}"
  
  replica {
    region = "us-west-2"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-api-keys"
    Application = each.key
  }
}

# IAM Roles for enhanced security
resource "aws_iam_role" "security_audit" {
  name = "${var.project_name}-security-audit-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "security-audit-${random_string.bucket_suffix.result}"
          }
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-security-audit-role"
  }
}

resource "aws_iam_role_policy_attachment" "security_audit" {
  role       = aws_iam_role.security_audit.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

# CloudTrail for API logging
resource "aws_cloudtrail" "main" {
  name           = "${var.project_name}-cloudtrail"
  s3_bucket_name = aws_s3_bucket.cloudtrail.id
  
  include_global_service_events = true
  is_multi_region_trail        = true
  enable_logging               = true
  
  event_selector {
    read_write_type                 = "All"
    include_management_events       = true
    exclude_management_event_sources = ["kms.amazonaws.com", "rdsdata.amazonaws.com"]
    
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.cloudtrail.arn}/*"]
    }
  }
  
  tags = {
    Name = "${var.project_name}-cloudtrail"
  }
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${random_string.bucket_suffix.result}"
  force_destroy = true
  
  tags = {
    Name = "${var.project_name}-cloudtrail"
  }
}

# KMS Key for encryption
resource "aws_kms_key" "security" {
  description             = "KMS key for security encryption"
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
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-security-kms"
  }
}

resource "aws_kms_alias" "security" {
  name          = "alias/${var.project_name}-security"
  target_key_id = aws_kms_key.security.key_id
}

# Network ACLs for additional security
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id
  
  # Allow inbound traffic from VPC
  ingress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }
  
  # Allow outbound traffic
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
  
  tags = {
    Name = "${var.project_name}-private-nacl"
  }
}

# Security Groups for database access
resource "aws_security_group" "database_admin" {
  name_prefix = "${var.project_name}-db-admin-"
  vpc_id      = aws_vpc.main.id
  
  # Restrict database access to specific IP ranges
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]  # Internal network only
  }
  
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]  # Internal network only
  }
  
  tags = {
    Name = "${var.project_name}-db-admin-sg"
  }
}
