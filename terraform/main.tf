module "sure" {
  source            = "github.com/resizes/platform-terraform-module-github-oidc-aws-role?ref=main"
  name              = "github-oidc-sure"
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
    "repo:chancenhq/sure:ref:refs/heads/main",
    "repo:chancenhq/sure:ref:refs/tags/v*"
  ]
}

resource "aws_ecr_repository" "sure" {
  name                 = "sure"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_iam_policy_document" "sure" {
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

resource "aws_ecr_repository_policy" "sure" {
  repository = aws_ecr_repository.sure.name
  policy     = data.aws_iam_policy_document.sure.json
}