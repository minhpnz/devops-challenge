variable "environment" {
  description = "Environment name. Becomes part of every resource name and of the OIDC subject."
  type        = string

  # Constrained rather than free-form: the value becomes part of an IAM role name
  # and of the OIDC subject the role trusts, so a typo here does not fail loudly —
  # it creates a second role nobody notices, trusted by an environment that does
  # not exist.
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be one of dev, staging, production. Adding a fourth means adding a root module under terraform/env/ and a matching GitHub Environment."
  }
}

variable "application" {
  description = "Application name used as a name prefix."
  type        = string
  default     = "backend"
}

variable "github_repository" {
  description = "GitHub repository in org/repo form. Scopes who may assume the deploy role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Must be exactly org/repo with no wildcards."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the account's GitHub Actions OIDC provider (output of envs/shared)."
  type        = string
}

# --- backend ---------------------------------------------------------------

variable "codedeploy_app_name" {
  description = "Shared CodeDeploy application name (output of envs/shared)."
  type        = string
}

variable "codedeploy_service_role_arn" {
  description = "IAM role CodeDeploy itself assumes to talk to EC2/ASG/ELB."
  type        = string
}

variable "artifact_bucket_arn" {
  description = "ARN of the shared revision bucket (output of envs/shared)."
  type        = string
}

variable "backend_url" {
  description = "Public HTTPS origin used by deployment smoke tests and the SPA runtime configuration."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.backend_url))
    error_message = "backend_url must be an HTTPS origin without a trailing slash or path."
  }
}

variable "autoscaling_group_name" {
  description = <<-EOT
    Name of the pre-existing ASG running the API. Application infrastructure
    (VPC, ALB, ASG) is assumed to exist and is out of scope for this problem —
    see SOLUTION.md §Assumptions.
  EOT
  type        = string
}

variable "target_group_name" {
  description = "ALB target group name CodeDeploy registers instances into."
  type        = string
}

variable "target_group_dimension" {
  description = "CloudWatch dimension value for the target group, e.g. targetgroup/api-prod/1234567890abcdef."
  type        = string
}

variable "load_balancer_dimension" {
  description = "CloudWatch dimension value for the ALB, e.g. app/api-prod/1234567890abcdef."
  type        = string
}

variable "error_alarm_threshold" {
  description = <<-EOT
    5xx responses per minute that trip the rollback alarm. Deliberately tighter
    than the paging threshold: this alarm's job is to stop a deployment, and a
    needless rollback is far cheaper than a shipped outage.
  EOT
  type        = number
  default     = 5
}

variable "latency_alarm_threshold_seconds" {
  description = "p99 target response time, in seconds, that trips the rollback alarm."
  type        = number
  default     = 1.0
}

variable "alarm_sns_topic_arns" {
  description = "SNS topics notified when a deploy-gate alarm changes state."
  type        = list(string)
  default     = []
}

# --- frontend --------------------------------------------------------------

variable "frontend_bucket_name" {
  description = "S3 bucket holding the SPA. Private; reachable only through CloudFront."
  type        = string
}

variable "frontend_aliases" {
  description = "Custom domains served by the distribution. Requires acm_certificate_arn."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN in us-east-1. Null uses the default CloudFront certificate."
  type        = string
  default     = null
}

variable "cloudfront_price_class" {
  description = <<-EOT
    PriceClass_200 covers North America, Europe and Asia — including Singapore
    and Hong Kong — at roughly half the cost of PriceClass_All, which adds South
    America, Australia and New Zealand. Revisit when real traffic shows users
    there.
  EOT
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "Must be one of PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

variable "web_acl_arn" {
  description = "Optional WAF web ACL ARN. Left null here; WAF is part of Problem 5."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
