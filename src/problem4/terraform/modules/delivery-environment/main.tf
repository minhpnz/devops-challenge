# Everything one environment needs in order to receive deployments:
#   - a CodeDeploy deployment group for the backend, with rollback alarms
#   - an S3 bucket + CloudFront distribution for the frontend
#   - the single IAM role GitHub Actions assumes to deploy into this environment
#
# One module, three environments, no behavioural copy-paste. The root modules are
# thin on purpose: environment-specific values are literals there, and all the
# logic lives here where it is reviewed once.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

locals {
  name_prefix = "${var.application}-${var.environment}"

  tags = merge(var.tags, {
    Environment = var.environment
    Application = var.application
    ManagedBy   = "terraform"
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Backend — CodeDeploy deployment group
# ---------------------------------------------------------------------------
resource "aws_codedeploy_deployment_group" "backend" {
  app_name              = var.codedeploy_app_name
  deployment_group_name = local.name_prefix
  service_role_arn      = var.codedeploy_service_role_arn

  # OneAtATime limits the blast radius. CodeDeploy does not move to instance 2
  # until instance 1 has rejoined the target group and AfterAllowTraffic passes.
  deployment_config_name = "CodeDeployDefault.OneAtATime"

  autoscaling_groups = [var.autoscaling_group_name]

  load_balancer_info {
    target_group_info {
      # CodeDeploy deregisters the instance from this target group before
      # ApplicationStop and re-registers it after ApplicationStart, so draining
      # is handled for us and no request is served by a stopping container.
      name = var.target_group_name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events = [
      "DEPLOYMENT_FAILURE",       # a lifecycle hook returned non-zero
      "DEPLOYMENT_STOP_ON_ALARM", # an alarm below fired mid-deployment
    ]
  }

  alarm_configuration {
    enabled = true
    alarms = [
      aws_cloudwatch_metric_alarm.error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.latency.alarm_name,
    ]

    # If CloudWatch itself is unavailable we cannot evaluate the alarms. Setting
    # this to true would mean "deploy anyway, blind" — during an AWS event, the
    # worst possible moment to be pushing new code.
    ignore_poll_alarm_failure = false
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Rollback alarms
#
# These are the deploy gate, and they are intentionally *tighter* than the
# paging alarms: an alarm that only fires once customers have noticed is useless
# as a rollback trigger. False positives here cost a rollback, which is cheap.
# False negatives cost an outage.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name  = "${local.name_prefix}-5xx"
  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    TargetGroup  = var.target_group_dimension
    LoadBalancer = var.load_balancer_dimension
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_alarm_threshold
  period              = 60
  evaluation_periods  = 2 # two consecutive minutes, not one spike
  datapoints_to_alarm = 2

  # notBreaching, not missing: zero requests during a quiet period must not read
  # as "unhealthy" and trigger a rollback of a perfectly good deployment.
  treat_missing_data = "notBreaching"

  alarm_description = "Backend 5xx rate for ${var.environment}. Wired to CodeDeploy auto-rollback."
  alarm_actions     = var.alarm_sns_topic_arns
  ok_actions        = var.alarm_sns_topic_arns

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name         = "${local.name_prefix}-p99-latency"
  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p99" # p99, not Average: the average hides the tail that users feel

  dimensions = {
    TargetGroup  = var.target_group_dimension
    LoadBalancer = var.load_balancer_dimension
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_alarm_threshold_seconds
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  alarm_description = "Backend p99 latency for ${var.environment}. Wired to CodeDeploy auto-rollback."
  alarm_actions     = var.alarm_sns_topic_arns
  ok_actions        = var.alarm_sns_topic_arns

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Frontend — private bucket behind CloudFront
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "frontend" {
  bucket = var.frontend_bucket_name
  tags   = local.tags
}

# The bucket is never a website endpoint and never public. CloudFront reaches it
# through Origin Access Control; S3 website hosting would require public objects
# and cannot do TLS on a custom domain at all.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  # Hashed assets are unique current objects, so a noncurrent-version rule would
  # never expire them. Deleting current assets by age can also break the live site
  # after a quiet release period. Keep them for this small V1; add a manifest-aware
  # cleanup job when storage growth becomes measurable.

  # Archived releases are the frontend's rollback targets; same 90-day horizon as
  # the backend revisions.
  rule {
    id     = "expire-release-archive"
    status = "Enabled"

    filter {
      prefix = "releases/"
    }

    expiration {
      days = 90
    }
  }

  # Versioning protects index.html/config.json from accidental overwrites, but
  # their old versions are not release archives and need not grow forever.
  rule {
    id     = "expire-noncurrent-entry-points"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name_prefix}-oac"
  description                       = "OAC for ${local.name_prefix} SPA bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Managed policies looked up by name rather than hardcoded by ID: the IDs are
# stable but opaque, and a reviewer can tell what "Managed-CachingDisabled" does.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.name_prefix
  default_root_object = "index.html"
  aliases             = var.frontend_aliases
  price_class         = var.cloudfront_price_class
  web_acl_id          = var.web_acl_arn

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Default behaviour: hashed assets, cached at the edge for as long as the
  # origin's Cache-Control says (one year, immutable).
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  # The two entry points are never cached at the edge. Without these behaviours a
  # deploy would be invisible until the edge TTL expired — and the invalidation
  # in the publish action would be doing all the work, once per deploy, forever.
  dynamic "ordered_cache_behavior" {
    for_each = toset(["/index.html", "/config.json"])
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "s3-frontend"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    }
  }

  # Client-side routing: /orders/123 is not an S3 object, so S3 returns 403 (it
  # returns 403 rather than 404 because ListBucket is not granted). Serving
  # index.html with a 200 lets the SPA router handle the path.
  #
  # This is also why a deep link cannot be used to distinguish "route not found"
  # from "asset missing" — accepted, and the smoke tests check assets explicitly
  # instead.
  dynamic "custom_error_response" {
    for_each = toset([403, 404])
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # Falls back to the CloudFront default certificate when no custom domain is
    # configured, so a fresh environment stands up without waiting on ACM.
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = var.acm_certificate_arn == null ? null : "sni-only"
    minimum_protocol_version       = var.acm_certificate_arn == null ? null : "TLSv1.2_2021"
    cloudfront_default_certificate = var.acm_certificate_arn == null
  }

  tags = local.tags
}

# Only this distribution may read the bucket. Scoping on AWS:SourceArn matters:
# without it the policy would permit *any* CloudFront distribution in any account
# to use this bucket as an origin.
data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}

# ---------------------------------------------------------------------------
# The deploy role for this environment
#
# One role per environment, scoped to that environment's resources. The staging
# role physically cannot write to the production bucket — so a copy-paste error
# in a workflow fails with AccessDenied instead of shipping untested code to
# customers.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy" {
  # Backend: start a deployment, and read the revision it names.
  statement {
    sid    = "CodeDeployRelease"
    effect = "Allow"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetDeploymentTarget",
      "codedeploy:ListDeployments",
      "codedeploy:ListDeploymentTargets",
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:GetApplicationRevision",
    ]
    resources = [
      "arn:aws:codedeploy:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:application:${var.codedeploy_app_name}",
      "arn:aws:codedeploy:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${var.codedeploy_app_name}/${local.name_prefix}",
      "arn:aws:codedeploy:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:deploymentconfig:*",
    ]
  }

  statement {
    sid       = "ReadRevisions"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${var.artifact_bucket_arn}/backend/*"]
  }

  # Frontend: write objects, but never reconfigure the bucket. No PutBucketPolicy,
  # no PutBucketPublicAccessBlock — a compromised pipeline can serve bad content
  # (recoverable by rollback) but cannot make the bucket public (not recoverable).
  statement {
    sid    = "PublishFrontend"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
  }

  statement {
    sid       = "ListFrontend"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.frontend.arn]
  }

  statement {
    sid    = "InvalidateCDN"
    effect = "Allow"
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = [aws_cloudfront_distribution.frontend.arn]
  }

  # Read-only. The bake loop reads alarms; it must not be able to disable one.
  statement {
    sid       = "ReadAlarms"
    effect    = "Allow"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"] # DescribeAlarms does not support resource-level permissions
  }
}

module "deploy_role" {
  source = "../gha-iam-role"

  name              = "github-actions-deploy-${var.environment}"
  description       = "GitHub Actions deploy role for ${var.environment}"
  oidc_provider_arn = var.oidc_provider_arn

  # Keyed to the GitHub Environment, not to a branch. For production this is the
  # mechanism that makes the reviewer gate load-bearing: a job without
  # `environment: production` cannot obtain this credential at all.
  allowed_subjects = ["repo:${var.github_repository}:environment:${var.environment}"]

  policy_json = data.aws_iam_policy_document.deploy.json
  tags        = local.tags
}
