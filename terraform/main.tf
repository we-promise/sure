module "companion" {
  source            = "github.com/resizes/platform-terraform-module-github-oidc-aws-role?ref=main"
  name              = "github-oidc-companion"
  org_name          = "resizes"
  condition_test    = "StringLike"
  actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetAuthorizationToken",
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
    "ecr:PutImage",
  ]
  assume_role_policy_condition_values = [
    "repo:chancenhq/companion:ref:refs/heads/main",
    "repo:chancenhq/companion:ref:refs/tags/v*",
    "repo:chancenhq/companion:ref:refs/heads/companion"
  ]
}

import {
  to = aws_ecr_repository.companion
  id = "companion"
}
resource "aws_ecr_repository" "companion" {
  name                 = "companion"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_iam_policy_document" "companion" {
  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["568619624687"]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability"
    ]
  }
}

resource "aws_ecr_repository_policy" "companion" {
  repository = aws_ecr_repository.companion.name
  policy     = data.aws_iam_policy_document.companion.json
}