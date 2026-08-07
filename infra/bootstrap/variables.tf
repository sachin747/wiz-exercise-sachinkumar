variable "aws_region" {
  description = "Region that holds the Terraform state bucket."
  type        = string
  # No pipeline runs this module - it's applied by hand once per AWS
  # account. Override with -var="aws_region=<region>" instead of editing
  # this default; whatever you pick here should match the AWS_REGION
  # GitHub variable used by infra.yml/app.yml, since that's the same
  # region infra/terraform will deploy into.
  default = "us-east-2"
}

variable "project_name" {
  description = "Prefix for all bootstrap resources."
  type        = string
  default     = "sachin-app"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the deploy role, as owner/repo."
  type        = string
}

variable "create_oidc_provider" {
  description = <<-EOT
    Whether to create the GitHub Actions OIDC provider. AWS allows only one
    provider per URL per account - leave this true for the first repo you
    bootstrap in an account, set it false for every repo after that in the
    same account (Terraform will look up the existing one instead).
  EOT
  type        = bool
  default     = true
}
