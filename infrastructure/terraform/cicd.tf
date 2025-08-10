# CodePipeline Configuration for ECS Workload Modernization
# Terraform configuration for creating CI/CD pipelines for all 10 applications

# S3 Bucket for CodePipeline Artifacts
resource "aws_s3_bucket" "codepipeline_artifacts" {
  bucket        = "${var.project_name}-codepipeline-artifacts-${random_string.bucket_suffix.result}"
  force_destroy = true
  
  tags = {
    Name = "${var.project_name}-codepipeline-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "codepipeline_artifacts" {
  bucket = aws_s3_bucket.codepipeline_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "codepipeline_artifacts" {
  bucket = aws_s3_bucket.codepipeline_artifacts.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "codepipeline_artifacts" {
  bucket = aws_s3_bucket.codepipeline_artifacts.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM Role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
  name = "${var.project_name}-codepipeline-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-codepipeline-role"
  }
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${var.project_name}-codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketVersioning",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = [
          aws_s3_bucket.codepipeline_artifacts.arn,
          "${aws_s3_bucket.codepipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = "*"
        Condition = {
          StringEqualsIfExists = {
            "iam:PassedToService" = [
              "ecs-tasks.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}

# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "${var.project_name}-codebuild-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-codebuild-role"
  }
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${var.project_name}-codebuild-policy"
  role = aws_iam_role.codebuild_role.id
  
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
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.codepipeline_artifacts.arn,
          "${aws_s3_bucket.codepipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# CodeBuild Projects for each application
resource "aws_codebuild_project" "apps" {
  for_each = toset(var.application_names)
  
  name          = "${var.project_name}-${each.key}-build"
  description   = "Build project for ${each.key} application"
  service_role  = aws_iam_role.codebuild_role.arn
  
  artifacts {
    type = "CODEPIPELINE"
  }
  
  environment {
    compute_type                = "BUILD_GENERAL1_MEDIUM"
    image                      = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                       = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode            = true
    
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = "${var.project_name}/${each.key}"
    }
    
    environment_variable {
      name  = "ECS_CLUSTER_NAME"
      value = aws_ecs_cluster.main.name
    }
    
    environment_variable {
      name  = "ECS_SERVICE_NAME"
      value = "${var.project_name}-${each.key}"
    }
  }
  
  source {
    type      = "CODEPIPELINE"
    buildspec = "cicd/buildspec/${each.key}-buildspec.yml"
  }
  
  cache {
    type     = "S3"
    location = "${aws_s3_bucket.codepipeline_artifacts.bucket}/cache/${each.key}"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-build"
    Application = each.key
  }
}

# CodePipeline for each application
resource "aws_codepipeline" "apps" {
  for_each = toset(var.application_names)
  
  name     = "${var.project_name}-${each.key}-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn
  
  artifact_store {
    location = aws_s3_bucket.codepipeline_artifacts.bucket
    type     = "S3"
    
    encryption_key {
      id   = aws_kms_key.cicd.arn
      type = "KMS"
    }
  }
  
  stage {
    name = "Source"
    
    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]
      
      configuration = {
        Owner      = "ruslanbaba"
        Repo       = "ecs-workload-modernization"
        Branch     = "main"
        OAuthToken = data.aws_ssm_parameter.github_token.value
      }
    }
  }
  
  stage {
    name = "Build"
    
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"
      
      configuration = {
        ProjectName = aws_codebuild_project.apps[each.key].name
      }
    }
  }
  
  stage {
    name = "SecurityScan"
    
    action {
      name             = "SecurityScan"
      category         = "Test"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["build_output"]
      output_artifacts = ["security_output"]
      version          = "1"
      
      configuration = {
        ProjectName = aws_codebuild_project.security_scan[each.key].name
      }
    }
  }
  
  stage {
    name = "DeployStaging"
    
    action {
      name            = "DeployToStaging"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["security_output"]
      version         = "1"
      
      configuration = {
        ClusterName = aws_ecs_cluster.main.name
        ServiceName = aws_ecs_service.apps[each.key].name
        FileName    = "imagedefinitions.json"
      }
    }
  }
  
  stage {
    name = "ApprovalGate"
    
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      
      configuration = {
        NotificationArn = aws_sns_topic.deployment_approvals.arn
        CustomData      = "Please review staging deployment and approve for production release of ${each.key}"
      }
    }
  }
  
  stage {
    name = "DeployProduction"
    
    action {
      name            = "DeployToProduction"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["security_output"]
      version         = "1"
      
      configuration = {
        ClusterName = aws_ecs_cluster.main.name
        ServiceName = aws_ecs_service.apps[each.key].name
        FileName    = "imagedefinitions.json"
      }
    }
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-pipeline"
    Application = each.key
  }
}

# CloudWatch Events for automated triggers
resource "aws_cloudwatch_event_rule" "deployment_events" {
  for_each = toset(var.application_names)
  
  name        = "${var.project_name}-${each.key}-deployment"
  description = "Trigger deployment for ${each.key} on code changes"
  
  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      state    = ["SUCCEEDED"]
      pipeline = [aws_codepipeline.apps[each.key].name]
    }
  })
  
  tags = {
    Name        = "${var.project_name}-${each.key}-deployment-events"
    Application = each.key
  }
}

# SNS Topic for deployment notifications
resource "aws_sns_topic" "deployment_notifications" {
  name = "${var.project_name}-deployment-notifications"
  
  tags = {
    Name = "${var.project_name}-deployment-notifications"
  }
}

resource "aws_sns_topic_subscription" "email_notifications" {
  topic_arn = aws_sns_topic.deployment_notifications.arn
  protocol  = "email"
  endpoint  = "platform-engineering@company.com"
}

# CloudWatch Event Targets for notifications
resource "aws_cloudwatch_event_target" "sns" {
  for_each = toset(var.application_names)
  
  rule      = aws_cloudwatch_event_rule.deployment_events[each.key].name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.deployment_notifications.arn
  
  input_transformer {
    input_paths = {
      pipeline = "$.detail.pipeline"
      state    = "$.detail.state"
    }
    input_template = "\"Pipeline <pipeline> has <state>\""
  }
}

# Blue/Green Deployment Configuration
resource "aws_codedeploy_application" "apps" {
  for_each = toset(var.application_names)
  
  compute_platform = "ECS"
  name             = "${var.project_name}-${each.key}-deploy"
  
  tags = {
    Name        = "${var.project_name}-${each.key}-deploy"
    Application = each.key
  }
}

# CodeDeploy Deployment Groups
resource "aws_codedeploy_deployment_group" "apps" {
  for_each = toset(var.application_names)
  
  app_name              = aws_codedeploy_application.apps[each.key].name
  deployment_group_name = "${var.project_name}-${each.key}-dg"
  service_role_arn      = aws_iam_role.codedeploy_role.arn
  
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
  
  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }
    
    terminate_blue_instances_on_deployment_success {
      action                         = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }
  
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-dg"
    Application = each.key
  }
}

# CodeDeploy Service Role
resource "aws_iam_role" "codedeploy_role" {
  name = "${var.project_name}-codedeploy-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${var.project_name}-codedeploy-role"
  }
}

resource "aws_iam_role_policy_attachment" "codedeploy_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForECS"
  role       = aws_iam_role.codedeploy_role.name
}

# Additional variable for GitHub token
# variable "github_token" {
#   description = "GitHub personal access token for CodePipeline"
#   type        = string
#   sensitive   = true
# }

# Data sources for secrets stored in AWS Systems Manager Parameter Store
data "aws_ssm_parameter" "github_token" {
  name            = "/ecs-modernization/github-token"
  with_decryption = true
}

# KMS Key for CI/CD encryption
resource "aws_kms_key" "cicd" {
  description             = "KMS key for CI/CD pipeline encryption"
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
        Sid    = "Allow CodePipeline and CodeBuild"
        Effect = "Allow"
        Principal = {
          Service = [
            "codepipeline.amazonaws.com",
            "codebuild.amazonaws.com"
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
    Name = "${var.project_name}-cicd-kms"
  }
}

resource "aws_kms_alias" "cicd" {
  name          = "alias/${var.project_name}-cicd"
  target_key_id = aws_kms_key.cicd.key_id
}

# Security scanning CodeBuild projects
resource "aws_codebuild_project" "security_scan" {
  for_each = toset(var.application_names)
  
  name          = "${var.project_name}-${each.key}-security-scan"
  description   = "Security scanning for ${each.key} application"
  service_role  = aws_iam_role.codebuild_role.arn
  
  artifacts {
    type = "CODEPIPELINE"
  }
  
  environment {
    compute_type                = "BUILD_GENERAL1_MEDIUM"
    image                      = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                       = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode            = true
    
    environment_variable {
      name  = "SONAR_TOKEN"
      type  = "SECRETS_MANAGER"
      value = "ecs-modernization/sonarqube:token"
    }
    
    environment_variable {
      name  = "SNYK_TOKEN"
      type  = "SECRETS_MANAGER"
      value = "ecs-modernization/snyk:token"
    }
  }
  
  source {
    type      = "CODEPIPELINE"
    buildspec = "cicd/buildspec/security-scan-buildspec.yml"
  }
  
  tags = {
    Name        = "${var.project_name}-${each.key}-security-scan"
    Application = each.key
  }
}

# SNS Topic for deployment approvals
resource "aws_sns_topic" "deployment_approvals" {
  name = "${var.project_name}-deployment-approvals"
  
  tags = {
    Name = "${var.project_name}-deployment-approvals"
  }
}

resource "aws_sns_topic_subscription" "deployment_approvals_email" {
  topic_arn = aws_sns_topic.deployment_approvals.arn
  protocol  = "email"
  endpoint  = "deployment-approvals@company.com"
}

resource "aws_sns_topic_subscription" "deployment_approvals_slack" {
  topic_arn = aws_sns_topic.deployment_approvals.arn
  protocol  = "https"
  endpoint  = "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
}
