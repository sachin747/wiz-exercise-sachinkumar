# Cloud-native security tooling - the third pillar of the exercise.
# Quick map of what's where: CloudTrail + EKS control plane logs handle
# audit (required). EBS encryption by default, S3 TLS-only, ECR scan-on-push,
# IMDSv2, and Pod Security Admission (see k8s/namespace.yaml) are the
# preventative side (the exercise requires at least one - this repo has
# several). Security Hub is the detective control (the exercise requires at
# least one). GuardDuty and AWS Config were dropped deliberately: the
# exercise only asks for one detective control, and running three
# overlapping tools added cost and complexity without covering anything
# Security Hub's foundational + CIS standards don't already catch. Security
# Hub was kept over the other two because its checks evaluate continuously
# against existing resource config, so findings are visible immediately
# rather than needing triggered activity (GuardDuty) or a recorder pipeline
# to spin up first (Config) - more reliable for a scheduled demo.

# --- audit: control plane logging ---

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "cloudtrail" {
  statement {
    sid       = "AclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "Write"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  # Reject unencrypted access to the audit log bucket - preventative control.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail.json
}

resource "aws_cloudtrail" "main" {
  name                          = var.project_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# --- preventative: account-wide guardrail ---

# Every EBS volume in this region gets encrypted whether the requester asked
# for it or not - blocks the mistake instead of just reporting it after.
resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}

# --- detective: Security Hub ---
# Foundational Security Best Practices + CIS standards cover every
# intentional weakness in this repo (public SSH, public bucket,
# overprivileged IAM, public EC2 IP, unencrypted transport, etc.) without
# needing custom rules the way Config did, or waiting on triggered activity
# the way GuardDuty did.

resource "aws_securityhub_account" "main" {
  count = var.enable_security_hub ? 1 : 0
}

resource "aws_securityhub_standards_subscription" "foundational" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.main]
}
