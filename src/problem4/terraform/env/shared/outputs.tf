# Consumed by the staging and production roots through terraform_remote_state.

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "ecr_repository_url" {
  description = "Backend image registry URL."
  value       = module.artifacts.ecr_repository_url
}

output "ecr_repository_arn" {
  description = "Backend image registry ARN."
  value       = module.artifacts.ecr_repository_arn
}

output "artifact_bucket" {
  description = "CodeDeploy revision bucket name — set this as the ARTIFACT_BUCKET repo variable."
  value       = module.artifacts.artifact_bucket
}

output "artifact_bucket_arn" {
  description = "CodeDeploy revision bucket ARN."
  value       = module.artifacts.artifact_bucket_arn
}

output "codedeploy_app_name" {
  description = "Shared CodeDeploy application name."
  value       = module.artifacts.codedeploy_app_name
}

output "build_role_arn" {
  description = "Role the build job assumes."
  value       = module.build_role.arn
}

output "terraform_plan_role_arn" {
  description = "Read-only role used by terraform plan on pull requests."
  value       = module.tf_plan_role.arn
}

output "terraform_apply_role_arn" {
  description = "Role used by terraform apply on main."
  value       = module.tf_apply_role.arn
}
