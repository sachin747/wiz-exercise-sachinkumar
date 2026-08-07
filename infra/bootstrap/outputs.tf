output "state_bucket_name" {
  description = "Set this as the `bucket` in infra/terraform/versions.tf backend block."
  value       = aws_s3_bucket.state.id
}

output "github_deploy_role_arn" {
  description = "Set this as the GitHub Actions repository variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}
