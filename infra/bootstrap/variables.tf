variable "aws_region" {
  description = "Region that holds the Terraform state bucket."
  type        = string
  default     = "us-east-2"
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
