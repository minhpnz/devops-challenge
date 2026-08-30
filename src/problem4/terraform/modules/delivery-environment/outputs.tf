# These outputs are exactly the values the workflows need as GitHub repository
# variables. Keeping them as outputs means the pipeline configuration is derived
# from the infrastructure rather than transcribed by hand — see the
# `github_variables` output for a copy-pasteable summary.

output "deploy_role_arn" {
  description = "Role the GitHub Actions deploy job assumes for this environment."
  value       = module.deploy_role.arn
}

output "frontend_bucket" {
  description = "SPA bucket name."
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "Distribution ID used for invalidations."
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  description = "Distribution domain name."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "codedeploy_deployment_group" {
  description = "Deployment group name used by the backend pipeline."
  value       = aws_codedeploy_deployment_group.backend.deployment_group_name
}

output "deploy_gate_alarms" {
  description = "Alarms the production bake step watches."
  value = [
    aws_cloudwatch_metric_alarm.error_rate.alarm_name,
    aws_cloudwatch_metric_alarm.latency.alarm_name,
  ]
}

output "github_variables" {
  description = "Values to set as GitHub repository/environment variables for this environment."
  value = {
    FRONTEND_BUCKET = aws_s3_bucket.frontend.bucket
    CLOUDFRONT_ID   = aws_cloudfront_distribution.frontend.id
    FRONTEND_URL    = length(var.frontend_aliases) > 0 ? "https://${var.frontend_aliases[0]}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"
    BACKEND_URL     = var.backend_url
    DEPLOY_ROLE_ARN = module.deploy_role.arn
  }
}
