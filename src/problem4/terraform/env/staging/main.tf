# Staging root module.
#
# Thin by design: environment-specific values are literals here, and every
# behaviour lives in ../../modules/delivery-environment. Two consequences worth
# noting:
#
#   - There is no `-var-file` flag anywhere in the infra workflow, so it is
#     impossible to apply production's values against staging's state. That
#     mistake is a common one and it is silent until someone notices production
#     is pointing at the staging API.
#   - This file and envs/production/main.tf are ~90% identical. That duplication
#     is accepted at two environments and is the explicit trigger for introducing
#     Terragrunt at the third (see SOLUTION.md §Part 2).

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
    key          = "problem4/staging/terraform.tfstate"
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
      Environment = "staging"
      ManagedBy   = "terraform"
      Repository  = "acme/web"
    }
  }
}

# Read-only reference to the shared state. Staging can see the registry ARN; it
# cannot modify anything the shared state owns.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "acme-tfstate-ap-southeast-1"
    key    = "problem4/shared/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

module "delivery" {
  source = "../../modules/delivery-environment"

  environment       = "staging"
  application       = "backend"
  github_repository = "acme/web"

  oidc_provider_arn           = data.terraform_remote_state.shared.outputs.oidc_provider_arn
  codedeploy_app_name         = data.terraform_remote_state.shared.outputs.codedeploy_app_name
  artifact_bucket_arn         = data.terraform_remote_state.shared.outputs.artifact_bucket_arn
  codedeploy_service_role_arn = "arn:aws:iam::111122223333:role/CodeDeployServiceRole"
  backend_url                 = "https://api.staging.example.com"

  # Pre-existing application infrastructure — see SOLUTION.md §Assumptions.
  autoscaling_group_name  = "api-staging-asg"
  target_group_name       = "api-staging-tg"
  target_group_dimension  = "targetgroup/api-staging-tg/0123456789abcdef"
  load_balancer_dimension = "app/api-staging-alb/0123456789abcdef"

  # Looser than production on purpose. Staging carries synthetic traffic and gets
  # deliberately broken builds; production thresholds here would mean a permanent
  # red alarm that everyone learns to ignore — and an alarm nobody trusts is worse
  # than no alarm.
  error_alarm_threshold           = 20
  latency_alarm_threshold_seconds = 2.0

  frontend_bucket_name = "acme-web-staging-ap-southeast-1"

  # No custom domain and no ACM certificate: staging is served on the default
  # CloudFront domain. PriceClass_100 because staging has no users outside the
  # office and edge coverage is not worth paying for.
  cloudfront_price_class = "PriceClass_100"
}

output "github_variables" {
  description = "Set these as GitHub environment variables for `staging`."
  value       = module.delivery.github_variables
}

output "cloudfront_domain_name" {
  description = "Where staging is served."
  value       = module.delivery.cloudfront_domain_name
}
