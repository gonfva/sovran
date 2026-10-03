data "aws_caller_identity" "current" {}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_kms_key" "client" {
  count = local.cmk_enabled ? 1 : 0

  description             = "Sovran CMK for client ${var.client_slug}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AgentTaskUse"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.task.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ReEncrypt*",
        ]
        Resource = "*"
      },
    ]
  })


  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-cmk"
    Component = "storage"
  })
}

resource "aws_kms_alias" "client" {
  count = local.cmk_enabled ? 1 : 0

  name          = "alias/${var.project_slug}-${var.client_slug}"
  target_key_id = aws_kms_key.client[0].key_id
}

resource "aws_s3_bucket" "code" {
  bucket        = "${var.project_slug}-${data.aws_caller_identity.current.account_id}-code-${var.client_slug}-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-code"
    Component = "storage"
  })
}

resource "aws_s3_bucket" "data" {
  bucket        = "${var.project_slug}-${data.aws_caller_identity.current.account_id}-data-${var.client_slug}-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-data"
    Component = "storage"
  })
}

resource "aws_s3_bucket_versioning" "code" {
  bucket = aws_s3_bucket.code.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = var.bucket_encryption
      # Null under AES256: SSE-S3 has no key to name.
      kms_master_key_id = local.cmk_enabled ? aws_kms_key.client[0].arn : null
    }
    # Harmless under AES256; under SSE-KMS it collapses per-object GenerateDataKey calls
    # into roughly one per refresh window, which is why the KMS traffic is negligible.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.bucket_encryption
      kms_master_key_id = local.cmk_enabled ? aws_kms_key.client[0].arn : null
    }
    bucket_key_enabled = true
  }
}

# Deny anything not on TLS. Every real caller (boto3 in the sync containers, Terraform,
# the AWS CLI) already uses HTTPS, so this costs nothing and converts an assumption into
# an enforced condition — the difference PLAN.md §6.2 asks for between "we don't route to
# the internet" and "the data plane rejects anything off-path".
#
# Deny statements do not make a bucket public, so these coexist with block_public_policy.
resource "aws_s3_bucket_policy" "code" {
  bucket = aws_s3_bucket.code.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.code.arn,
          "${aws_s3_bucket.code.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  # A bucket policy and the public access block race on create; without this, an apply can
  # fail with AccessDenied because BPA is evaluating a policy that is still being written.
  depends_on = [aws_s3_bucket_public_access_block.code]
}

resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.data.arn,
          "${aws_s3_bucket.data.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.data]
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Seed objects so sync-down has something to pull (and exit demos can list docs).
#
# Encryption is deliberately left to the bucket default rather than named here: it applies
# in both bucket_encryption modes, and duplicating it would only create a second place to
# get wrong. data_hello doubles as the KMS proof — sync-down GetObject's it every task
# start, so if SSE-KMS ever needed a VPC-side KMS path, the agent would never come up.
#
# depends_on is load-bearing, not decoration. aws_s3_object only implicitly depends on the
# bucket, so without this Terraform races the upload against the encryption configuration
# and wins: on the 2026-08-14 live apply both seed objects landed as AES256 under a bucket
# whose default was the CMK. Nothing failed — the objects were readable and the agent came
# up — so the only symptom was head-object disagreeing with get-bucket-encryption. An
# earlier revision hid this by naming the SSE on each object; the dependency is the fix
# that survives bucket_encryption = "AES256" too.
resource "aws_s3_object" "code_readme" {
  bucket       = aws_s3_bucket.code.id
  key          = "README.md"
  content      = "# Client ${var.client_slug} code bundle\n\nSynced into /workspace/code by sync-down.\n"
  content_type = "text/markdown"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.code]
}

resource "aws_s3_object" "data_hello" {
  bucket       = aws_s3_bucket.data.id
  key          = "documents/hello.txt"
  content      = "Hello from client ${var.client_slug} documents prefix.\n"
  content_type = "text/plain"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.data]
}
