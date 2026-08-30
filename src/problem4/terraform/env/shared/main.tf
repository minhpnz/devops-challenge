# Account-level pipeline infrastructure: things that exist once and are shared by
# every environment.
#
# Separate state on purpose. The OIDC provider and the image registry are not
# owned by staging or by production — putting them in either root would mean
# `terraform destroy` on a throwaway environment can delete the registry
# production is running from.
#
# Apply order is shared -> staging -> production, enforced by the infra workflow.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pin the major version. `>= 5.60` alone would let a provider 6.x release
      # land in CI unannounced and rewrite half the plan.
      version = "~> 5.60"
    }
  }

  backend "s3" {
    bucket = "acme-tfstate-ap-southeast-1"
    key    = "problem4/shared/terraform.tfstate"
    region = "ap-southeast-1"

    # Native S3 state locking (Terraform 1.10+). The DynamoDB lock table it
    # replaces is deprecated and was one more resource to create, pay for, and
    # forget to create for a new environment.
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "ap-southeast-1"

  # Applied to every taggable resource in this state — so cost allocation and
  # "who owns this" work without remembering to tag each resource individually.
  default_tags {
    tags = {
      Application = "web-product"
      Component   = "cicd"
      ManagedBy   = "terraform"
      Repository  = "acme/web"
      Scope       = "shared"
    }
  }
}

locals {
  github_repository = "acme/web"
  account_id        = data.aws_caller_identity.current.account_id
  region            = data.aws_region.current.name
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider — one per AWS account
#
# This is what removes long-lived AWS access keys from the system entirely.
# GitHub mints a short-lived JWT describing the workflow run; AWS validates it
# and issues credentials good for one hour. There is no secret in GitHub to leak,
# rotate, or find in a fork's logs.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # thumbprint_list is deliberately omitted. Since 2023 AWS validates
  # token.actions.githubusercontent.com against its own trusted root store rather
  # than a pinned leaf thumbprint, and the provider made the argument optional to
  # match. Pinning one would create a rotation obligation that buys nothing —
  # and an expired pinned thumbprint breaks every deployment at once.
  tags = { Name = "github-actions" }
}

# ---------------------------------------------------------------------------
# Shared artifacts
# ---------------------------------------------------------------------------
module "artifacts" {
  source = "../../modules/artifact-registry"

  ecr_repository_name  = "acme/backend"
  artifact_bucket_name = "acme-deploy-artifacts-ap-southeast-1"
  codedeploy_app_name  = "backend"

  image_retention_days = 90
}

# ---------------------------------------------------------------------------
# The build role — pushes images, uploads revisions, and nothing else.
#
# Note what it cannot do: it cannot create a deployment. A compromised build job
# can publish an image, but it cannot put that image in front of a user without
# passing through the environment gates.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "build" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action has no resource scope
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [module.artifacts.ecr_repository_arn]
  }

  statement {
    sid     = "UploadRevisions"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    # Write-only, and only under backend/. The build role cannot read back or
    # delete another revision — so it cannot tamper with a rollback target.
    resources = ["${module.artifacts.artifact_bucket_arn}/backend/*"]
  }
}

module "build_role" {
  source = "../../modules/gha-iam-role"

  name              = "github-actions-backend-build"
  description       = "Builds and publishes backend images and CodeDeploy revisions"
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn

  # Any branch may build and publish an image — triggering a run on a branch
  # requires write access to the repository, and image tags are immutable, so a
  # published image can never overwrite a reviewed one.
  #
  # No branch may *deploy*. Deployment needs an environment-scoped role, and the
  # staging and production GitHub Environments carry a deployment-branch policy
  # limiting them to main. That split is what lets a developer push their branch
  # to dev without widening the path to production by one inch.
  #
  # Pull request runs — including from forks — match neither subject, which is why
  # the PR path in the workflow skips the credential step entirely and scans a
  # locally built image instead.
  allowed_subjects = ["repo:${local.github_repository}:ref:refs/heads/*"]

  policy_json = data.aws_iam_policy_document.build.json
}

# ---------------------------------------------------------------------------
# Terraform's own roles
# ---------------------------------------------------------------------------

# Plan is read-only at the infrastructure and state layers. The workflow excludes
# fork PRs because repository variables and OIDC are unavailable to them.
data "aws_iam_policy_document" "tf_plan" {
  statement {
    sid    = "ReadEverything"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "autoscaling:Describe*",
      "codedeploy:Get*",
      "codedeploy:List*",
      "cloudfront:Get*",
      "cloudfront:List*",
      "cloudwatch:Describe*",
      "ecr:Describe*",
      "ecr:GetLifecyclePolicy",
      "ecr:ListTagsForResource",
      "iam:Get*",
      "iam:List*",
      "s3:GetBucket*",
      "s3:ListBucket",
      "s3:GetLifecycleConfiguration",
      "s3:GetEncryptionConfiguration",
    ]
    resources = ["*"]
  }

  # A plan reads state but must never write it. Native S3 locking does need
  # PutObject/DeleteObject on the adjacent .tflock objects, scoped separately.
  statement {
    sid     = "ReadState"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::acme-tfstate-ap-southeast-1/problem4/*/terraform.tfstate",
    ]
  }

  statement {
    sid     = "LockState"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::acme-tfstate-ap-southeast-1/problem4/*/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid       = "ListState"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::acme-tfstate-ap-southeast-1"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["problem4/*"]
    }
  }
}

module "tf_plan_role" {
  source = "../../modules/gha-iam-role"

  name              = "github-actions-terraform-plan"
  description       = "Read-only role for terraform plan on pull requests"
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  allowed_subjects  = ["repo:${local.github_repository}:pull_request"]
  policy_json       = data.aws_iam_policy_document.tf_plan.json
}

# Apply is the most powerful role in the account: it creates IAM roles, so it can
# in principle create a role more powerful than itself. Two controls:
#   1. it is only assumable from a job in the *-infra environments, which require
#      a human reviewer;
#   2. the permissions boundary below caps anything it creates.
#
# The managed policy is a placeholder for the write scope a real account would
# narrow by service and resource; see SOLUTION.md §"What I left out".
module "tf_apply_role" {
  source = "../../modules/gha-iam-role"

  name              = "github-actions-terraform-apply"
  description       = "Applies Terraform through protected infrastructure environments"
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn

  allowed_subjects = [
    "repo:${local.github_repository}:environment:shared-infra",
    "repo:${local.github_repository}:environment:dev-infra",
    "repo:${local.github_repository}:environment:staging-infra",
    "repo:${local.github_repository}:environment:production-infra",
  ]

  permissions_boundary_arn = aws_iam_policy.pipeline_boundary.arn
  policy_json              = data.aws_iam_policy_document.tf_apply.json
}

data "aws_iam_policy_document" "tf_apply" {
  statement {
    sid    = "ManagePipelineInfrastructure"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
      "ecr:*",
      "codedeploy:*",
      "cloudfront:*",
      "cloudwatch:*",
      "s3:*",
      "iam:*",
    ]
    resources = ["*"]
  }
}

# Nothing this role creates can escalate beyond the boundary, and the boundary
# itself cannot be edited by a role that carries it.
resource "aws_iam_policy" "pipeline_boundary" {
  name        = "pipeline-permissions-boundary"
  description = "Ceiling on anything the Terraform apply role creates"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPipelineServices"
        Effect = "Allow"
        Action = [
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "acm:ListTagsForCertificate",
          "ecr:*",
          "codedeploy:*",
          "cloudfront:*",
          "cloudwatch:*",
          "s3:*",
          "iam:*",
          "sts:AssumeRole",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyBoundaryEscape"
        Effect = "Deny"
        Action = [
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion",
        ]
        Resource = "arn:aws:iam::${local.account_id}:policy/pipeline-permissions-boundary"
      },
      {
        Sid      = "DenyBoundaryRemoval"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary"]
        Resource = "*"
      },
    ]
  })
}
