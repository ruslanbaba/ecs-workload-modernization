# Variables for ECS Workload Modernization Infrastructure

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "ecs-modernization"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones_count" {
  description = "Number of availability zones"
  type        = number
  default     = 3
}

variable "application_names" {
  description = "List of application names for ECR repositories"
  type        = list(string)
  default = [
    "crm-system",
    "erp-platform",
    "trading-system",
    "supply-chain-mgmt",
    "hris",
    "bi-dashboard",
    "inventory-mgmt",
    "document-platform",
    "ecommerce",
    "monitoring-system"
  ]
}

# ECS Task Configuration Variables
variable "ecs_task_cpu" {
  description = "CPU units for ECS tasks"
  type        = map(number)
  default = {
    "crm-system"         = 1024
    "erp-platform"       = 2048
    "trading-system"     = 4096
    "supply-chain-mgmt"  = 1024
    "hris"              = 512
    "bi-dashboard"       = 2048
    "inventory-mgmt"     = 1024
    "document-platform"  = 1024
    "ecommerce"         = 2048
    "monitoring-system"  = 512
  }
}

variable "ecs_task_memory" {
  description = "Memory for ECS tasks"
  type        = map(number)
  default = {
    "crm-system"         = 2048
    "erp-platform"       = 4096
    "trading-system"     = 8192
    "supply-chain-mgmt"  = 2048
    "hris"              = 1024
    "bi-dashboard"       = 4096
    "inventory-mgmt"     = 2048
    "document-platform"  = 2048
    "ecommerce"         = 4096
    "monitoring-system"  = 1024
  }
}

variable "desired_count" {
  description = "Desired number of tasks for each application"
  type        = map(number)
  default = {
    "crm-system"         = 3
    "erp-platform"       = 5
    "trading-system"     = 2
    "supply-chain-mgmt"  = 3
    "hris"              = 2
    "bi-dashboard"       = 3
    "inventory-mgmt"     = 3
    "document-platform"  = 2
    "ecommerce"         = 5
    "monitoring-system"  = 2
  }
}

variable "application_ports" {
  description = "Port numbers for each application"
  type        = map(number)
  default = {
    "crm-system"         = 8080
    "erp-platform"       = 8081
    "trading-system"     = 8082
    "supply-chain-mgmt"  = 8083
    "hris"              = 8084
    "bi-dashboard"       = 3000
    "inventory-mgmt"     = 8085
    "document-platform"  = 8086
    "ecommerce"         = 8087
    "monitoring-system"  = 8088
  }
}

variable "health_check_paths" {
  description = "Health check paths for each application"
  type        = map(string)
  default = {
    "crm-system"         = "/health"
    "erp-platform"       = "/api/health"
    "trading-system"     = "/status"
    "supply-chain-mgmt"  = "/health"
    "hris"              = "/health"
    "bi-dashboard"       = "/api/health"
    "inventory-mgmt"     = "/health"
    "document-platform"  = "/api/health"
    "ecommerce"         = "/health"
    "monitoring-system"  = "/metrics"
  }
}

# Auto Scaling Configuration
variable "min_capacity" {
  description = "Minimum capacity for auto scaling"
  type        = map(number)
  default = {
    "crm-system"         = 2
    "erp-platform"       = 3
    "trading-system"     = 1
    "supply-chain-mgmt"  = 2
    "hris"              = 1
    "bi-dashboard"       = 2
    "inventory-mgmt"     = 2
    "document-platform"  = 1
    "ecommerce"         = 3
    "monitoring-system"  = 1
  }
}

variable "max_capacity" {
  description = "Maximum capacity for auto scaling"
  type        = map(number)
  default = {
    "crm-system"         = 10
    "erp-platform"       = 20
    "trading-system"     = 5
    "supply-chain-mgmt"  = 10
    "hris"              = 5
    "bi-dashboard"       = 10
    "inventory-mgmt"     = 10
    "document-platform"  = 5
    "ecommerce"         = 20
    "monitoring-system"  = 3
  }
}

# Database Configuration
variable "database_engines" {
  description = "Database engines for each application"
  type        = map(string)
  default = {
    "crm-system"         = "mysql"
    "erp-platform"       = "sqlserver-ex"
    "trading-system"     = "postgres"
    "supply-chain-mgmt"  = "postgres"
    "hris"              = "mysql"
    "bi-dashboard"       = "postgres"
    "inventory-mgmt"     = "postgres"
    "document-platform"  = "oracle-ee"
    "ecommerce"         = "mysql"
    "monitoring-system"  = "postgres"
  }
}

variable "database_instance_classes" {
  description = "RDS instance classes for each application"
  type        = map(string)
  default = {
    "crm-system"         = "db.t3.large"
    "erp-platform"       = "db.m5.2xlarge"
    "trading-system"     = "db.r5.4xlarge"
    "supply-chain-mgmt"  = "db.t3.xlarge"
    "hris"              = "db.t3.medium"
    "bi-dashboard"       = "db.r5.2xlarge"
    "inventory-mgmt"     = "db.t3.large"
    "document-platform"  = "db.m5.xlarge"
    "ecommerce"         = "db.r5.xlarge"
    "monitoring-system"  = "db.t3.small"
  }
}

# Security Configuration
variable "enable_waf" {
  description = "Enable AWS WAF for applications"
  type        = bool
  default     = true
}

variable "enable_shield" {
  description = "Enable AWS Shield Advanced"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Backup retention period in days"
  type        = number
  default     = 30
}

# Monitoring Configuration
variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 30
}

# Cost Optimization
variable "enable_spot_instances" {
  description = "Enable Fargate Spot instances for cost optimization"
  type        = bool
  default     = true
}

variable "spot_allocation_percentage" {
  description = "Percentage of tasks to run on Spot instances"
  type        = number
  default     = 50
}
