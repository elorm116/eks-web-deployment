# ── ECR Repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "web_app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"  # tags cannot be overwritten — enforces digest-based deploys

  image_scanning_configuration {
    scan_on_push = true  # basic CVE scan on every push, free tier
  }

  encryption_configuration {
    encryption_type = "KMS"  # default AES-256 is fine for most; KMS gives you audit trail + key control
  }

  tags = {
    Project   = "eks-web-deployment"
    ManagedBy = "terraform"
  }

  lifecycle {
    prevent_destroy = true  # ECR must survive EKS teardowns — images are not recoverable
  }
}

# ── Lifecycle Policy ──────────────────────────────────────────────────────────
# Prevents unbounded image accumulation — keep last 30 tagged, expire untagged after 1 day

resource "aws_ecr_lifecycle_policy" "web_app" {
  repository = aws_ecr_repository.web_app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}