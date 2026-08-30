# Shared artifact storage: one ECR repository for backend images, one S3 bucket
# for CodeDeploy revisions.
#
# Deliberately account-wide and environment-agnostic. "Build once, promote many"
# only holds if staging and production read the same objects; a per-environment
# registry would force a rebuild (or a copy) between them and quietly break the
# invariant the whole pipeline is built on.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "backend" {
  name = var.ecr_repository_name

  # The strongest single setting in this file. With IMMUTABLE, `git-<sha>` can
  # never be repointed at different content — so "the digest that passed staging"
  # and "the tag we deployed" can never disagree, and an attacker with push access
  # cannot overwrite an already-reviewed image.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Trivy already blocks the build on fixable HIGH/CRITICAL. This catches the
    # other case: a CVE disclosed *after* the image was published, which no
    # build-time gate can ever see.
    scan_on_push = true
  }

  encryption_configuration {
    # AES256 (SSE-S3) rather than KMS: images are not secret, and per-pull KMS
    # requests add cost and an extra failure mode to every instance launch.
    # Switch to KMS if a compliance regime requires customer-managed keys.
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  # Without this, storage grows forever at ~250MB per merge. With it, the
  # repository stabilises at a few GB and costs under a dollar a month.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep release images for ${var.image_retention_days} days"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["git-"]
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = var.image_retention_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged layers after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CodeDeploy revisions
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifact_bucket_name

  # Deleting this bucket orphans every rollback target the fleet has. Losing it
  # during an incident is unrecoverable, so make it impossible to do by accident.
  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    # Revision keys are content-addressed by commit SHA and never overwritten, so
    # versioning is not needed for correctness — it is here to survive an
    # accidental or malicious delete of a rollback target.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-revisions"
    status = "Enabled"

    filter {
      prefix = "backend/"
    }

    # 90 days of rollback history. Rolling back further than that is not a
    # deployment problem any more — the schema has moved on and the old revision
    # would not run against the current database.
    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny any request that is not TLS. S3 endpoints are public by definition; without
# this an accidental http:// URL in a script silently downgrades the transport.
data "aws_iam_policy_document" "artifacts" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

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

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts.json
}

# ---------------------------------------------------------------------------
# CodeDeploy application
# ---------------------------------------------------------------------------
# The application is shared; deployment groups are per environment and live in
# the delivery-environment module.
resource "aws_codedeploy_app" "backend" {
  name             = var.codedeploy_app_name
  compute_platform = "Server"
  tags             = var.tags
}
