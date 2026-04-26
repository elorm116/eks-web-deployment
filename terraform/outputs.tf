output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}"
}

output "github_actions_role_arn" {
  description = "Role ARN to use in configure-aws-credentials"
  value       = aws_iam_role.github_actions.arn
}