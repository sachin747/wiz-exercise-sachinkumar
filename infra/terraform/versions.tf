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

  # Bucket name and region both come in at init time, not written here, so
  # this file never needs an edit for a different account or region:
  #   terraform init -backend-config="bucket=<state_bucket_name>" -backend-config="region=<aws_region>"
  # Backend blocks can't reference variables (Terraform has to know where
  # state lives before it evaluates anything else), so this is the only
  # correct way to keep the region out of this file.
  backend "s3" {
    key          = "sachin-app/terraform.tfstate"
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
