variable "name" {
  description = "Role name, e.g. github-actions-deploy-production."
  type        = string

  validation {
    condition     = can(regex("^github-actions-[a-z0-9-]+$", var.name))
    error_message = "Name must start with github-actions- so these roles are greppable in CloudTrail."
  }
}

variable "description" {
  description = "What this role is for. Shows up in the console when someone asks 'what is this'."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the account's GitHub Actions OIDC provider."
  type        = string
}

variable "allowed_subjects" {
  description = <<-EOT
    Allowed values of the token's `sub` claim, e.g.
    ["repo:acme/web:environment:production"]. Wildcards are permitted but each
    one widens who can assume this role — justify them in code review.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_subjects) > 0
    error_message = "At least one subject is required; an empty list would trust nothing but reads as if it trusts everything."
  }

  validation {
    # `repo:*` or `*` would let any repository on GitHub assume the role. This is
    # the single highest-severity misconfiguration in the whole design, so it is
    # rejected in code rather than left to review.
    condition     = alltrue([for s in var.allowed_subjects : can(regex("^repo:[^*]+/[^*]+:", s))])
    error_message = "Each subject must name a specific org/repo; wildcards in the repository segment would trust every repository on GitHub."
  }
}

variable "policy_json" {
  description = "Inline permissions policy for the role, as JSON."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary ARN capping what this role can ever do."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
