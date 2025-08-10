# Outputs for ECS Workload Modernization Infrastructure

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "ecs_cluster_id" {
  description = "ID of the ECS cluster"
  value       = aws_ecs_cluster.main.id
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.main.arn
}

output "application_load_balancer_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "application_load_balancer_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "application_load_balancer_zone_id" {
  description = "Zone ID of the Application Load Balancer"
  value       = aws_lb.main.zone_id
}

output "ecr_repository_urls" {
  description = "URLs of ECR repositories"
  value = {
    for k, v in aws_ecr_repository.apps : k => v.repository_url
  }
}

output "security_group_alb_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb.id
}

output "security_group_ecs_tasks_id" {
  description = "ID of the ECS tasks security group"
  value       = aws_security_group.ecs_tasks.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key for ECS encryption"
  value       = aws_kms_key.ecs.arn
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group for ECS exec"
  value       = aws_cloudwatch_log_group.ecs_exec.name
}

output "s3_alb_logs_bucket" {
  description = "Name of the S3 bucket for ALB logs"
  value       = aws_s3_bucket.alb_logs.id
}

output "nat_gateway_ips" {
  description = "Elastic IP addresses of NAT gateways"
  value       = aws_eip.nat[*].public_ip
}

# Application-specific outputs
output "application_configurations" {
  description = "Configuration details for each application"
  value = {
    for app in var.application_names : app => {
      name            = app
      ecr_url         = aws_ecr_repository.apps[app].repository_url
      port            = var.application_ports[app]
      health_check    = var.health_check_paths[app]
      cpu             = var.ecs_task_cpu[app]
      memory          = var.ecs_task_memory[app]
      desired_count   = var.desired_count[app]
      min_capacity    = var.min_capacity[app]
      max_capacity    = var.max_capacity[app]
      database_engine = var.database_engines[app]
      instance_class  = var.database_instance_classes[app]
    }
  }
  sensitive = false
}

# VPC Endpoints
output "vpc_endpoints" {
  description = "VPC endpoint details"
  value = {
    s3_endpoint_id      = aws_vpc_endpoint.s3.id
    ecr_dkr_endpoint_id = aws_vpc_endpoint.ecr_dkr.id
    ecr_api_endpoint_id = aws_vpc_endpoint.ecr_api.id
  }
}

# Cost optimization information
output "cost_optimization_summary" {
  description = "Summary of cost optimization features enabled"
  value = {
    fargate_spot_enabled        = var.enable_spot_instances
    spot_allocation_percentage  = var.spot_allocation_percentage
    vpc_endpoints_enabled      = true
    detailed_monitoring        = var.enable_detailed_monitoring
    log_retention_days         = var.log_retention_days
    backup_retention_days      = var.backup_retention_days
  }
}

# Security features
output "security_features" {
  description = "Summary of security features enabled"
  value = {
    waf_enabled                = var.enable_waf
    shield_advanced_enabled    = var.enable_shield
    container_insights_enabled = true
    kms_encryption_enabled     = true
    vpc_flow_logs_enabled      = true
    ecr_scan_on_push_enabled   = true
  }
}

# Network configuration summary
output "network_summary" {
  description = "Network configuration summary"
  value = {
    vpc_cidr                = var.vpc_cidr
    availability_zones      = data.aws_availability_zones.available.names
    public_subnets_count    = length(aws_subnet.public)
    private_subnets_count   = length(aws_subnet.private)
    nat_gateways_count      = length(aws_nat_gateway.main)
    internet_gateway_id     = aws_internet_gateway.main.id
  }
}
