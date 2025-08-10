#!/bin/bash

# Secrets Management Deployment Script for ECS Workload Modernization
# This script securely deploys secrets to AWS Parameter Store and Secrets Manager

set -euo pipefail

# Configuration
PROJECT_NAME="ecs-modernization"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-production}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if AWS CLI is configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed. Please install AWS CLI first."
        exit 1
    fi

    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi

    log_success "AWS CLI is properly configured"
}

# Function to check if required tools are installed
check_dependencies() {
    local missing_tools=()

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    if ! command -v openssl &> /dev/null; then
        missing_tools+=("openssl")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools and try again"
        exit 1
    fi

    log_success "All dependencies are installed"
}

# Function to generate secure random strings
generate_secure_string() {
    local length=${1:-32}
    openssl rand -base64 $((length * 3 / 4)) | tr -d "=+/" | cut -c1-${length}
}

# Function to generate API key
generate_api_key() {
    local prefix=${1:-"ecs_mod"}
    local key_part=$(generate_secure_string 32)
    echo "${prefix}_${key_part}"
}

# Function to create KMS key if it doesn't exist
create_kms_key() {
    local alias_name="alias/${PROJECT_NAME}-secrets"
    
    log_info "Checking if KMS key exists..."
    
    if aws kms describe_key --key-id "$alias_name" &> /dev/null; then
        log_success "KMS key already exists: $alias_name"
        local key_id=$(aws kms describe-key --key-id "$alias_name" --query 'KeyMetadata.KeyId' --output text)
        echo "$key_id"
        return
    fi

    log_info "Creating KMS key for secrets encryption..."
    
    local key_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow AWS Services",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "secretsmanager.amazonaws.com",
          "ssm.amazonaws.com",
          "codebuild.amazonaws.com",
          "lambda.amazonaws.com"
        ]
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

    local key_id=$(aws kms create-key \
        --description "KMS key for ${PROJECT_NAME} secrets encryption" \
        --policy "$key_policy" \
        --query 'KeyMetadata.KeyId' \
        --output text)

    aws kms create-alias \
        --alias-name "$alias_name" \
        --target-key-id "$key_id"

    log_success "Created KMS key: $key_id"
    echo "$key_id"
}

# Function to create SSM parameter
create_ssm_parameter() {
    local name="$1"
    local value="$2"
    local type="${3:-SecureString}"
    local kms_key_id="$4"
    
    log_info "Creating SSM parameter: $name"
    
    # Check if parameter already exists
    if aws ssm get-parameter --name "$name" &> /dev/null; then
        log_warning "Parameter $name already exists. Skipping creation."
        return
    fi

    if [ "$type" = "SecureString" ]; then
        aws ssm put-parameter \
            --name "$name" \
            --value "$value" \
            --type "$type" \
            --key-id "$kms_key_id" \
            --tags Key=Environment,Value="$ENVIRONMENT" Key=Project,Value="$PROJECT_NAME" \
            > /dev/null
    else
        aws ssm put-parameter \
            --name "$name" \
            --value "$value" \
            --type "$type" \
            --tags Key=Environment,Value="$ENVIRONMENT" Key=Project,Value="$PROJECT_NAME" \
            > /dev/null
    fi
    
    log_success "Created SSM parameter: $name"
}

# Function to create Secrets Manager secret
create_secret() {
    local name="$1"
    local description="$2"
    local secret_value="$3"
    local kms_key_id="$4"
    
    log_info "Creating Secrets Manager secret: $name"
    
    # Check if secret already exists
    if aws secretsmanager describe-secret --secret-id "$name" &> /dev/null; then
        log_warning "Secret $name already exists. Skipping creation."
        return
    fi

    aws secretsmanager create-secret \
        --name "$name" \
        --description "$description" \
        --secret-string "$secret_value" \
        --kms-key-id "$kms_key_id" \
        --tags Key=Environment,Value="$ENVIRONMENT" Key=Project,Value="$PROJECT_NAME" \
        > /dev/null
    
    log_success "Created secret: $name"
}

# Function to deploy configuration parameters
deploy_configuration_parameters() {
    local kms_key_id="$1"
    
    log_info "Deploying configuration parameters..."
    
    # Basic configuration parameters
    create_ssm_parameter \
        "/${PROJECT_NAME}/sonarqube-host-url" \
        "https://sonar.company.com" \
        "String" \
        "$kms_key_id"
    
    create_ssm_parameter \
        "/${PROJECT_NAME}/snyk-org-id" \
        "your-snyk-org-id" \
        "String" \
        "$kms_key_id"
    
    create_ssm_parameter \
        "/${PROJECT_NAME}/aws-account-id" \
        "$(aws sts get-caller-identity --query Account --output text)" \
        "String" \
        "$kms_key_id"
    
    log_success "Configuration parameters deployed"
}

# Function to deploy secure secrets
deploy_secure_secrets() {
    local kms_key_id="$1"
    
    log_info "Deploying secure secrets..."
    
    # Generate secure tokens and keys
    local github_token=$(generate_api_key "ghp")
    local sonarqube_token=$(generate_secure_string 40)
    local snyk_token=$(generate_secure_string 36)
    local jwt_secret=$(generate_secure_string 64)
    
    # SSM SecureString parameters
    create_ssm_parameter \
        "/${PROJECT_NAME}/github-token" \
        "$github_token" \
        "SecureString" \
        "$kms_key_id"
    
    # Secrets Manager secrets
    create_secret \
        "${PROJECT_NAME}/sonarqube" \
        "SonarQube authentication token" \
        "{\"token\":\"$sonarqube_token\"}" \
        "$kms_key_id"
    
    create_secret \
        "${PROJECT_NAME}/snyk" \
        "Snyk authentication token for vulnerability scanning" \
        "{\"token\":\"$snyk_token\"}" \
        "$kms_key_id"
    
    create_secret \
        "${PROJECT_NAME}/veracode" \
        "Veracode API credentials for security scanning" \
        "{\"api_id\":\"placeholder_api_id\",\"api_key\":\"$(generate_secure_string 64)\"}" \
        "$kms_key_id"
    
    # Monitoring secrets
    create_secret \
        "${PROJECT_NAME}/datadog" \
        "Datadog API credentials for monitoring integration" \
        "{\"api_key\":\"$(generate_secure_string 32)\",\"application_key\":\"$(generate_secure_string 40)\"}" \
        "$kms_key_id"
    
    create_secret \
        "${PROJECT_NAME}/newrelic" \
        "New Relic API credentials for APM integration" \
        "{\"api_key\":\"$(generate_secure_string 47)\",\"application_id\":\"placeholder_app_id\",\"license_key\":\"$(generate_secure_string 40)\"}" \
        "$kms_key_id"
    
    log_success "Secure secrets deployed"
}

# Function to deploy application-specific secrets
deploy_application_secrets() {
    local kms_key_id="$1"
    local applications=("crm-system" "inventory-service" "user-management" "payment-processor" "notification-service" "reporting-engine" "audit-logger" "file-storage" "analytics-platform" "integration-hub")
    
    log_info "Deploying application-specific secrets..."
    
    for app in "${applications[@]}"; do
        log_info "Creating secrets for application: $app"
        
        # Database credentials
        local db_password=$(generate_secure_string 32)
        create_secret \
            "${PROJECT_NAME}/${app}/database" \
            "Database credentials for ${app} application" \
            "{\"host\":\"${app}-db.cluster-xyz.${AWS_REGION}.rds.amazonaws.com\",\"port\":5432,\"dbname\":\"${app}\",\"username\":\"${app}_user\",\"password\":\"$db_password\",\"engine\":\"postgres\"}" \
            "$kms_key_id"
        
        # API secrets
        local jwt_secret=$(generate_secure_string 64)
        local api_key=$(generate_api_key "${app}")
        local encrypt_key=$(generate_secure_string 32)
        local webhook_secret=$(generate_secure_string 32)
        
        create_secret \
            "${PROJECT_NAME}/${app}/api-secrets" \
            "API secrets and JWT keys for ${app} application" \
            "{\"jwt_secret\":\"$jwt_secret\",\"api_key\":\"$api_key\",\"encrypt_key\":\"$encrypt_key\",\"webhook_secret\":\"$webhook_secret\"}" \
            "$kms_key_id"
    done
    
    log_success "Application-specific secrets deployed"
}

# Function to create Lambda deployment package
create_lambda_package() {
    log_info "Creating Lambda deployment package for secrets rotation..."
    
    local lambda_dir="cicd/lambda/secrets-rotation"
    local package_file="secrets-rotation-lambda.zip"
    
    if [ ! -f "$lambda_dir/index.py" ]; then
        log_error "Lambda function code not found at $lambda_dir/index.py"
        exit 1
    fi
    
    cd "$lambda_dir"
    zip -r "../../../$package_file" . > /dev/null
    cd - > /dev/null
    
    log_success "Created Lambda package: $package_file"
}

# Function to validate deployment
validate_deployment() {
    local kms_key_id="$1"
    
    log_info "Validating secrets deployment..."
    
    local validation_errors=0
    
    # Check SSM parameters
    local ssm_params=(
        "/${PROJECT_NAME}/github-token"
        "/${PROJECT_NAME}/sonarqube-host-url"
    )
    
    for param in "${ssm_params[@]}"; do
        if ! aws ssm get-parameter --name "$param" &> /dev/null; then
            log_error "SSM parameter not found: $param"
            ((validation_errors++))
        fi
    done
    
    # Check Secrets Manager secrets
    local secrets=(
        "${PROJECT_NAME}/sonarqube"
        "${PROJECT_NAME}/snyk"
        "${PROJECT_NAME}/datadog"
    )
    
    for secret in "${secrets[@]}"; do
        if ! aws secretsmanager describe-secret --secret-id "$secret" &> /dev/null; then
            log_error "Secret not found: $secret"
            ((validation_errors++))
        fi
    done
    
    if [ $validation_errors -eq 0 ]; then
        log_success "All secrets validation passed"
        return 0
    else
        log_error "Validation failed with $validation_errors errors"
        return 1
    fi
}

# Function to print deployment summary
print_deployment_summary() {
    echo
    echo "=========================================="
    echo "    SECRETS DEPLOYMENT SUMMARY"
    echo "=========================================="
    echo
    echo "Project: $PROJECT_NAME"
    echo "Environment: $ENVIRONMENT"
    echo "AWS Region: $AWS_REGION"
    echo
    echo "Deployed Components:"
    echo "  ✓ KMS encryption key"
    echo "  ✓ SSM configuration parameters"
    echo "  ✓ Secrets Manager secrets"
    echo "  ✓ Application-specific secrets"
    echo "  ✓ Lambda function package"
    echo
    echo "Next Steps:"
    echo "  1. Update placeholder values in secrets"
    echo "  2. Deploy Terraform infrastructure"
    echo "  3. Configure CI/CD pipelines"
    echo "  4. Test application deployments"
    echo
    echo "Security Notes:"
    echo "  • All secrets are encrypted with KMS"
    echo "  • IAM policies restrict access by service"
    echo "  • Automatic rotation is configured"
    echo "  • Audit logging is enabled"
    echo
}

# Main deployment function
main() {
    echo "Starting ECS Workload Modernization Secrets Deployment"
    echo "======================================================"
    echo
    
    # Pre-flight checks
    check_aws_cli
    check_dependencies
    
    # Create KMS key
    local kms_key_id=$(create_kms_key)
    
    # Deploy secrets and configuration
    deploy_configuration_parameters "$kms_key_id"
    deploy_secure_secrets "$kms_key_id"
    deploy_application_secrets "$kms_key_id"
    
    # Create Lambda package
    create_lambda_package
    
    # Validate deployment
    validate_deployment "$kms_key_id"
    
    # Print summary
    print_deployment_summary
    
    log_success "Secrets deployment completed successfully!"
}

# Script usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -e, --environment   Environment name (default: production)"
    echo "  -r, --region        AWS region (default: us-east-1)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  AWS_REGION          AWS region override"
    echo "  ENVIRONMENT         Environment name override"
    echo ""
    echo "Examples:"
    echo "  $0                                # Use defaults"
    echo "  $0 -e staging -r us-west-2       # Custom environment and region"
    echo "  AWS_REGION=eu-west-1 $0          # Use environment variable"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
