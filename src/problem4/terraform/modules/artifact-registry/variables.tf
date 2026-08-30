variable "ecr_repository_name" {
  description = "ECR repository holding backend images, e.g. acme/backend."
  type        = string
}

variable "artifact_bucket_name" {
  description = "S3 bucket holding CodeDeploy revisions. Must be globally unique."
  type        = string
}

variable "codedeploy_app_name" {
  description = "CodeDeploy application name shared by all environments."
  type        = string
  default     = "backend"
}

variable "image_retention_days" {
  description = <<-EOT
    Days to keep tagged release images. This matches the CodeDeploy revision
    window so an archived rollback target cannot outlive its container image.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.image_retention_days >= 30
    error_message = "Keep at least 30 days of images so rollback history survives a busy release month."
  }
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
