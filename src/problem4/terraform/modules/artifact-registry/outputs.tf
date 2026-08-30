output "ecr_repository_arn" {
  description = "ARN of the backend ECR repository."
  value       = aws_ecr_repository.backend.arn
}

output "ecr_repository_url" {
  description = "Registry URL used by the build workflow."
  value       = aws_ecr_repository.backend.repository_url
}

output "artifact_bucket" {
  description = "Name of the CodeDeploy revision bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifact_bucket_arn" {
  description = "ARN of the CodeDeploy revision bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "codedeploy_app_name" {
  description = "Shared CodeDeploy application name."
  value       = aws_codedeploy_app.backend.name
}
