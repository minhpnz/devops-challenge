# Dev root module.
#
# Dev exists to answer "does my branch work on real AWS?" before it is merged. It
# is therefore the only environment deployed from an arbitrary branch, via
# workflow_dispatch, and the only one where a broken deploy is expected rather
# than an incident.
#
# It is deliberately the cheapest of the three: no custom domain, no ACM
# certificate, PriceClass_100, and alarm thresholds loose enough that a
# half-finished feature does not trip a rollback. What it does keep is the exact
# deployment mechanism used by production — CodeDeploy, the same lifecycle hooks,
# the same publish ordering. An environment that deploys differently from
# production tests the wrong thing.

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
    key          = "problem4/dev/terraform.tfstate"
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
      Environment = "dev"
      ManagedBy   = "terraform"
      Repository  = "acme/web"
    }
  }
}

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

  environment       = "dev"
  application       = "backend"
  github_repository = "acme/web"

  oidc_provider_arn           = data.terraform_remote_state.shared.outputs.oidc_provider_arn
  codedeploy_app_name         = data.terraform_remote_state.shared.outputs.codedeploy_app_name
  artifact_bucket_arn         = data.terraform_remote_state.shared.outputs.artifact_bucket_arn
  codedeploy_service_role_arn = "arn:aws:iam::111122223333:role/CodeDeployServiceRole"
  backend_url                 = "https://api.dev.example.com"

  # A single-instance ASG. Dev has no availability requirement, and one instance
  # is a third of staging's bill.
  autoscaling_group_name  = "api-dev-asg"
  target_group_name       = "api-dev-tg"
  target_group_dimension  = "targetgroup/api-dev-tg/00112233445566ff"
  load_balancer_dimension = "app/api-dev-alb/00112233445566ff"

  # Loose enough not to fight developers. Note the consequence, which is the point
  # of writing it down: at one instance, OneAtATime has no canary property here —
  # dev tests that the deployment *mechanism* works, not that the change is safe.
  error_alarm_threshold           = 100
  latency_alarm_threshold_seconds = 5.0

  frontend_bucket_name   = "acme-web-dev-ap-southeast-1"
  cloudfront_price_class = "PriceClass_100"
}

output "github_variables" {
  description = "Set these as GitHub environment variables for `dev`."
  value       = module.delivery.github_variables
}

output "cloudfront_domain_name" {
  description = "Where dev is served."
  value       = module.delivery.cloudfront_domain_name
}
