# ── GitHub Actions OIDC Provider ─────────────────────────────────────────────
# Allows GitHub Actions to assume AWS roles without static credentials.
# One provider per AWS account — if it already exists, import it instead.

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint — stable, but verify at:
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1",
                     "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# ── IAM Role for GitHub Actions ───────────────────────────────────────────────

resource "aws_iam_role" "github_actions" {
  name = "github-actions-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Locks to your repo only — change * to ref:refs/heads/main
          # if you want to restrict push access to main branch exclusively
          "token.actions.githubusercontent.com:sub" = "repo:elorm116/eks-web-deployment:*"
        }
      }
    }]
  })

  tags = {
    Project   = "eks-web-deployment"
    ManagedBy = "terraform"
  }
}

# ── ECR Policy ────────────────────────────────────────────────────────────────
# Least-privilege: only what the pipeline needs

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "github-actions-ecr-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"  # GetAuthorizationToken doesn't support resource scoping
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:DescribeImages"
        ]
        Resource = aws_ecr_repository.web_app.arn      }
    ]
  })
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}