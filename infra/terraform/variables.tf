variable "aws_region" {
  description = "AWS region for the whole environment."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Prefix applied to resource names."
  type        = string
  default     = "sachin-app"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "sachin-app-cluster"
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane version. Confirm the value is still supported before
    applying:  aws eks describe-cluster-versions --region us-east-2
  EOT
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "Instance type for the private EKS worker nodes."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired worker node count."
  type        = number
  default     = 2
}

variable "mongo_instance_type" {
  description = "Instance type for the MongoDB VM."
  type        = string
  default     = "t3.small"
}

variable "ssh_public_key" {
  description = <<-EOT
    OpenSSH public key installed on the MongoDB VM. Required to demonstrate the
    'SSH exposed to the internet' finding interactively. Leave empty to skip the
    key pair (the security group still opens port 22 to 0.0.0.0/0).
  EOT
  type        = string
  default     = ""
}

variable "mongo_app_password" {
  description = <<-EOT
    Password for the MongoDB application user (todo_app). No AWS Secrets
    Manager involved -- set this once as a GitHub Actions secret
    (MONGO_APP_PASSWORD) and it flows into both this Terraform run (to
    create the Mongo user) and the app pipeline (to build MONGODB_URI). It
    never appears in git. Rotating it means updating the GitHub secret and
    re-running both pipelines.
  EOT
  type        = string
  sensitive   = true
}

variable "cluster_admin_role_arn" {
  description = <<-EOT
    Optional extra IAM role/user ARN granted EKS cluster-admin, so you can run
    kubectl from your laptop as well as from CI. Leave empty to skip.
  EOT
  type        = string
  default     = ""
}

variable "enable_guardduty" {
  description = "Set false if GuardDuty is already enabled in this account/region."
  type        = bool
  default     = true
}

variable "enable_aws_config" {
  description = "Set false if an AWS Config recorder already exists in this account/region."
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "Set false if Security Hub is already enabled in this account/region."
  type        = bool
  default     = true
}
