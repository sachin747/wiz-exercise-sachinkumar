terraform {
  # 1.10+ is required for S3 native state locking (`use_lockfile`).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Bucket name comes from `terraform output state_bucket_name` in infra/bootstrap.
  # It is passed at init time so this file needs no edits:
  #   terraform init -backend-config="bucket=<state_bucket_name>"
  backend "s3" {
    key          = "sachin-app/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Exercise  = "wiz-technical-exercise"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
