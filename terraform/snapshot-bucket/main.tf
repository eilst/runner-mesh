locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "runner-mesh-etcd-snapshots-${random_id.suffix.hex}"
}

# Globally-unique suffix so the default bucket name doesn't collide.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "snapshots" {
  bucket = local.bucket_name
  tags   = var.tags
}

# Snapshots are cluster secrets in effect (etcd holds every Secret object) —
# lock the bucket down hard.
resource "aws_s3_bucket_public_access_block" "snapshots" {
  bucket                  = aws_s3_bucket.snapshots.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Keep the last-N snapshots recoverable even if one is corrupted, but don't
# let versions accumulate forever.
resource "aws_s3_bucket_versioning" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id
  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    filter {
      prefix = "${var.snapshot_folder}/"
    }
    expiration {
      days = var.retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.retention_days
    }
  }
}

# Least-privilege identity for k3s: read/write/list/delete only this
# bucket's snapshot objects — nothing else in the account.
resource "aws_iam_user" "snapshots" {
  name = var.iam_user_name
  tags = var.tags
}

resource "aws_iam_access_key" "snapshots" {
  user = aws_iam_user.snapshots.name
}

data "aws_iam_policy_document" "snapshots" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.snapshots.arn]
  }
  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.snapshots.arn}/*"]
  }
}

resource "aws_iam_user_policy" "snapshots" {
  name   = "runner-mesh-etcd-snapshots"
  user   = aws_iam_user.snapshots.name
  policy = data.aws_iam_policy_document.snapshots.json
}
