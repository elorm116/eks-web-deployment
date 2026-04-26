# backend.tf — single terraform block with both backend + required_providers
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.37"
    }
  }

  backend "s3" {
    bucket       = "mali-terraform-state-eks"
    key          = "eks/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}