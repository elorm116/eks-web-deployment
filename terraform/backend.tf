terraform {
  backend "s3" {
    bucket = "mali-terraform-state-eks"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
    use_lockfile = true
    encrypt = true
  }
}
