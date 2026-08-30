# Production root module. See envs/staging/main.tf for why these roots are thin
# and why the duplication between them is deliberate.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  backend "s3" {
    bucket       = "acme-tfstate-ap-southeast-1"
    key          = "problem4/production/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "ap-southeast-1"

  default_tags {
    tags = {
      Application = "web-product"
      Component   = "cicd"
      Environment = "production"
      ManagedBy   = "terraform"
      Repository  = "acme/web"
    }
  }
}

# ACM certificates for CloudFront must live in us-east-1 regardless of where the
# rest of the stack runs. This aliased provider exists only for that lookup.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "acme-tfstate-ap-southeast-1"
    key    = "problem4/shared/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "aws_acm_certificate" "frontend" {
  provider    = aws.us_east_1
  domain      = "example.com"
  statuses    = ["ISSUED"]
  most_recent = true
}

module "delivery" {
  source = "../../modules/delivery-environment"

  environment       = "production"
  application       = "backend"
  github_repository = "acme/web"

  oidc_provider_arn           = data.terraform_remote_state.shared.outputs.oidc_provider_arn
  codedeploy_app_name         = data.terraform_remote_state.shared.outputs.codedeploy_app_name
  artifact_bucket_arn         = data.terraform_remote_state.shared.outputs.artifact_bucket_arn
  codedeploy_service_role_arn = "arn:aws:iam::111122223333:role/CodeDeployServiceRole"
  backend_url                 = "https://api.example.com"

  autoscaling_group_name  = "api-production-asg"
  target_group_name       = "api-production-tg"
  target_group_dimension  = "targetgroup/api-production-tg/fedcba9876543210"
  load_balancer_dimension = "app/api-production-alb/fedcba9876543210"

  # 5 x 5xx/minute for two consecutive minutes. At the ~500 rps of Problem 1 that
  # is a 0.017% error rate — low enough that reaching it means something is
  # genuinely wrong, high enough that a single client retrying a bad request does
  # not roll back a good deployment.
  error_alarm_threshold           = 5
  latency_alarm_threshold_seconds = 1.0

  # Rollback alarms page as well as gate: a rollback that nobody is told about is
  # a mystery for whoever deploys next.
  alarm_sns_topic_arns = ["arn:aws:sns:ap-southeast-1:111122223333:platform-alerts"]

  frontend_bucket_name = "acme-web-production-ap-southeast-1"
  frontend_aliases     = ["example.com", "www.example.com"]
  acm_certificate_arn  = data.aws_acm_certificate.frontend.arn

  cloudfront_price_class = "PriceClass_200"

  # web_acl_arn is intentionally left null — WAF belongs to the security pass in
  # Problem 5, and wiring it here would claim protection this problem does not
  # actually deliver.
}

output "github_variables" {
  description = "Set these as GitHub environment variables for `production`."
  value       = module.delivery.github_variables
}

output "deploy_gate_alarms" {
  description = "Alarm names the production bake step watches. Must match backend-pipeline.yml."
  value       = module.delivery.deploy_gate_alarms
}
