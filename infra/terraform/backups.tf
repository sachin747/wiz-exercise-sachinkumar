# MongoDB backup bucket. The PDF requires it to be public read + public
# list, so this whole file is basically that one weakness: anyone can list
# s3://<bucket>/daily/ and pull down a full mongodump. Config rules
# s3-bucket-public-read-prohibited / s3-bucket-level-public-access-prohibited
# and Security Hub S3.2/S3.8 all catch it; Macie would too if it's enabled.

resource "aws_s3_bucket" "backups" {
  bucket        = "${var.project_name}-mongo-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# All four public-access guards off - required for the policy below to work.
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "backups" {
  # Anyone can list the bucket contents.
  statement {
    sid       = "PublicList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  # Anyone can download any backup archive.
  statement {
    sid       = "PublicRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  policy     = data.aws_iam_policy_document.backups.json
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = 14
    }

    noncurrent_version_expiration {
      noncurrent_days = 14
    }
  }
}
