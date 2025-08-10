# Deployment Automation Script
# Enterprise-level deployment orchestration for all 10 applications

#!/bin/bash

set -e

# Configuration
PROJECT_NAME="ecs-modernization"
AWS_REGION="us-east-1"
ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"
CLUSTER_NAME="${PROJECT_NAME}-cluster"

# Application list with deployment order (low-risk first)
APPLICATIONS=(
    "monitoring-system"
    "bi-dashboard"
    "supply-chain-mgmt"
    "inventory-mgmt"
    "hris"
    "crm-system"
    "ecommerce"
    "document-platform"
    "erp-platform"
    "trading-system"
)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Prerequisite checks
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
    fi
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install it first."
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Please run 'aws configure'."
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running. Please start Docker."
    fi
    
    success "Prerequisites check completed"
}

# ECR login
ecr_login() {
    log "Logging into Amazon ECR..."
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
    success "ECR login successful"
}

# Build and push Docker image
build_and_push() {
    local app_name=$1
    local image_tag=${2:-latest}
    
    log "Building and pushing $app_name..."
    
    # Build Docker image
    log "Building Docker image for $app_name..."
    docker build -t $app_name:$image_tag applications/$app_name/
    
    # Tag for ECR
    docker tag $app_name:$image_tag $ECR_REGISTRY/$PROJECT_NAME/$app_name:$image_tag
    docker tag $app_name:$image_tag $ECR_REGISTRY/$PROJECT_NAME/$app_name:latest
    
    # Security scan (optional - requires Trivy or similar)
    if command -v trivy &> /dev/null; then
        log "Running security scan for $app_name..."
        trivy image --exit-code 1 --severity HIGH,CRITICAL $ECR_REGISTRY/$PROJECT_NAME/$app_name:$image_tag || warning "Security scan found issues"
    fi
    
    # Push to ECR
    log "Pushing image to ECR..."
    docker push $ECR_REGISTRY/$PROJECT_NAME/$app_name:$image_tag
    docker push $ECR_REGISTRY/$PROJECT_NAME/$app_name:latest
    
    success "Successfully built and pushed $app_name"
}

# Update ECS service
update_service() {
    local app_name=$1
    local service_name="${PROJECT_NAME}-${app_name}"
    
    log "Updating ECS service: $service_name..."
    
    # Get current task definition
    local task_def_arn=$(aws ecs describe-services \
        --cluster $CLUSTER_NAME \
        --services $service_name \
        --query 'services[0].taskDefinition' \
        --output text)
    
    if [ "$task_def_arn" == "None" ]; then
        error "Service $service_name not found"
    fi
    
    # Force new deployment
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $service_name \
        --force-new-deployment \
        --query 'service.serviceName' \
        --output text
    
    success "Service update initiated for $app_name"
}

# Wait for deployment to complete
wait_for_deployment() {
    local app_name=$1
    local service_name="${PROJECT_NAME}-${app_name}"
    local max_attempts=30
    local attempt=1
    
    log "Waiting for deployment to complete for $app_name..."
    
    while [ $attempt -le $max_attempts ]; do
        local deployment_status=$(aws ecs describe-services \
            --cluster $CLUSTER_NAME \
            --services $service_name \
            --query 'services[0].deployments[?status==`PRIMARY`].rolloutState' \
            --output text)
        
        if [ "$deployment_status" == "COMPLETED" ]; then
            success "Deployment completed for $app_name"
            return 0
        elif [ "$deployment_status" == "FAILED" ]; then
            error "Deployment failed for $app_name"
        fi
        
        log "Deployment in progress... (attempt $attempt/$max_attempts)"
        sleep 30
        ((attempt++))
    done
    
    error "Deployment timeout for $app_name"
}

# Health check
health_check() {
    local app_name=$1
    local max_attempts=10
    local attempt=1
    
    log "Performing health check for $app_name..."
    
    # Get ALB DNS name
    local alb_dns=$(aws elbv2 describe-load-balancers \
        --names "${PROJECT_NAME}-alb" \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    while [ $attempt -le $max_attempts ]; do
        if curl -f -s "http://$alb_dns/$app_name/health" > /dev/null; then
            success "Health check passed for $app_name"
            return 0
        fi
        
        log "Health check attempt $attempt/$max_attempts for $app_name"
        sleep 10
        ((attempt++))
    done
    
    warning "Health check failed for $app_name - manual verification required"
}

# Deploy single application
deploy_application() {
    local app_name=$1
    local image_tag=${2:-latest}
    
    log "Starting deployment for $app_name..."
    
    # Build and push
    build_and_push $app_name $image_tag
    
    # Update service
    update_service $app_name
    
    # Wait for deployment
    wait_for_deployment $app_name
    
    # Health check
    health_check $app_name
    
    # Record deployment metrics
    aws cloudwatch put-metric-data \
        --namespace "ECS/Deployments" \
        --metric-data \
        MetricName=DeploymentSuccess,Value=1,Unit=Count,Dimensions=Application=$app_name \
        MetricName=DeploymentDuration,Value=$(date +%s),Unit=Seconds,Dimensions=Application=$app_name
    
    success "Deployment completed for $app_name"
}

# Deploy all applications
deploy_all() {
    local start_time=$(date +%s)
    local failed_deployments=()
    
    log "Starting deployment of all applications..."
    log "Deployment order: ${APPLICATIONS[*]}"
    
    for app in "${APPLICATIONS[@]}"; do
        log "=================================="
        log "Deploying application: $app"
        log "=================================="
        
        if deploy_application $app; then
            success "✓ $app deployed successfully"
        else
            error "✗ $app deployment failed"
            failed_deployments+=($app)
        fi
        
        # Brief pause between deployments
        sleep 10
    done
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    log "=================================="
    log "DEPLOYMENT SUMMARY"
    log "=================================="
    log "Total deployment time: ${total_time} seconds"
    log "Applications deployed: ${#APPLICATIONS[@]}"
    
    if [ ${#failed_deployments[@]} -eq 0 ]; then
        success "All applications deployed successfully!"
        
        # Record overall success metric
        aws cloudwatch put-metric-data \
            --namespace "ECS/Deployments" \
            --metric-data \
            MetricName=BatchDeploymentSuccess,Value=1,Unit=Count \
            MetricName=BatchDeploymentDuration,Value=$total_time,Unit=Seconds
    else
        warning "Failed deployments: ${failed_deployments[*]}"
        
        # Record failure metric
        aws cloudwatch put-metric-data \
            --namespace "ECS/Deployments" \
            --metric-data \
            MetricName=BatchDeploymentFailure,Value=1,Unit=Count
        
        exit 1
    fi
}

# Rollback function
rollback_application() {
    local app_name=$1
    local service_name="${PROJECT_NAME}-${app_name}"
    
    log "Rolling back $app_name..."
    
    # Get previous task definition
    local task_definitions=$(aws ecs list-task-definitions \
        --family-prefix "${PROJECT_NAME}-${app_name}" \
        --status ACTIVE \
        --sort DESC \
        --query 'taskDefinitionArns[1]' \
        --output text)
    
    if [ "$task_definitions" == "None" ]; then
        error "No previous task definition found for rollback"
    fi
    
    # Update service with previous task definition
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $service_name \
        --task-definition $task_definitions
    
    wait_for_deployment $app_name
    success "Rollback completed for $app_name"
}

# Infrastructure validation
validate_infrastructure() {
    log "Validating infrastructure..."
    
    # Check ECS cluster
    if ! aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].status' --output text | grep -q ACTIVE; then
        error "ECS cluster $CLUSTER_NAME is not active"
    fi
    
    # Check ALB
    if ! aws elbv2 describe-load-balancers --names "${PROJECT_NAME}-alb" &> /dev/null; then
        error "Application Load Balancer not found"
    fi
    
    # Check ECR repositories
    for app in "${APPLICATIONS[@]}"; do
        if ! aws ecr describe-repositories --repository-names "${PROJECT_NAME}/${app}" &> /dev/null; then
            warning "ECR repository for $app not found - creating..."
            aws ecr create-repository --repository-name "${PROJECT_NAME}/${app}"
        fi
    done
    
    success "Infrastructure validation completed"
}

# Main function
main() {
    local action=${1:-deploy-all}
    local app_name=$2
    local image_tag=${3:-latest}
    
    case $action in
        "deploy-all")
            check_prerequisites
            ecr_login
            validate_infrastructure
            deploy_all
            ;;
        "deploy")
            if [ -z "$app_name" ]; then
                error "Application name required for single deployment"
            fi
            check_prerequisites
            ecr_login
            validate_infrastructure
            deploy_application $app_name $image_tag
            ;;
        "rollback")
            if [ -z "$app_name" ]; then
                error "Application name required for rollback"
            fi
            check_prerequisites
            rollback_application $app_name
            ;;
        "validate")
            check_prerequisites
            validate_infrastructure
            ;;
        *)
            echo "Usage: $0 [deploy-all|deploy|rollback|validate] [app-name] [image-tag]"
            echo ""
            echo "Commands:"
            echo "  deploy-all                 Deploy all applications in order"
            echo "  deploy <app-name> [tag]    Deploy single application"
            echo "  rollback <app-name>        Rollback single application"
            echo "  validate                   Validate infrastructure"
            echo ""
            echo "Available applications:"
            for app in "${APPLICATIONS[@]}"; do
                echo "  - $app"
            done
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
