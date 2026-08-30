# A single IAM role assumable by GitHub Actions through OIDC.
#
# Factored into a module because the trust policy is the security boundary of the
# whole pipeline, and a boundary that is copy-pasted five times is a boundary that
# is subtly different in five places.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Without this the role trusts any OIDC token AWS can validate — including
    # tokens minted for someone else's repository.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The actual authorization decision. `sub` encodes which repository, and
    # which context within it, requested the token:
    #
    #   repo:org/repo:environment:production  only a job with `environment:
    #                                         production`, i.e. one that has
    #                                         already cleared the required
    #                                         reviewer gate
    #   repo:org/repo:ref:refs/heads/main     only a run on the main branch
    #   repo:org/repo:pull_request            any pull request, forks included
    #
    # This is why the production role is genuinely unusable without approval:
    # the credential cannot be minted at all outside an approved job. A reviewer
    # rule alone would only be a convention.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.allowed_subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = var.description
  path        = "/github-actions/"

  assume_role_policy = data.aws_iam_policy_document.trust.json

  # A GitHub Actions job runs for minutes, not hours. Capping the session at one
  # hour bounds the damage from a leaked credential; the default of 12h does not.
  max_session_duration = 3600

  # Even if an attached policy grants more, this ceiling applies. Defence against
  # a future policy edit that is broader than intended.
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_role_policy" "inline" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
