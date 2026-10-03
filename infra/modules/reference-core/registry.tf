# S3 static Docker registry (PLAN.md Phase 8), created only when registry_mode = "s3".
#
# A registry pull is just two GETs: /v2/<repo>/manifests/<ref> and /v2/<repo>/blobs/<digest>.
# S3 serves both from static objects, so the images arrive over the free gateway endpoint
# and the ecr.api / ecr.dkr interface endpoints can be deleted. Push with
# scripts/push-images-s3.py, which renders the layout and sets the Content-Types.
#
# The bucket name deliberately matches the ${project_slug}-${account}-* pattern the gateway
# endpoint policy already allows, so it needs no special case there.

resource "aws_s3_bucket" "registry" {
  count = local.registry_s3 ? 1 : 0

  bucket        = "${var.project_slug}-${data.aws_caller_identity.current.account_id}-registry"
  force_destroy = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-registry"
    Component = "platform"
  })
}

resource "aws_s3_bucket_public_access_block" "registry" {
  count = local.registry_s3 ? 1 : 0

  bucket                  = aws_s3_bucket.registry[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3, not the SSE-KMS used for client buckets, and not by oversight.
#
# The registry is read by an *anonymous* principal — Fargate's image puller sends no
# credentials at all. An anonymous caller cannot hold kms:Decrypt, so an SSE-KMS object is
# unreadable to it and every pull would fail. SSE-S3 keeps encryption at rest without a key
# the caller has to be authorized against. The contents are public container images, not
# client data, so there is nothing here a per-client CMK would be protecting.
resource "aws_s3_bucket_server_side_encryption_configuration" "registry" {
  count = local.registry_s3 ? 1 : 0

  bucket = aws_s3_bucket.registry[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning so a re-push cannot silently destroy the bytes a live task definition pins.
# Digests make that mostly theoretical, but the tag keys are overwritten on every push.
resource "aws_s3_bucket_versioning" "registry" {
  count = local.registry_s3 ? 1 : 0

  bucket = aws_s3_bucket.registry[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Anonymous read, but only through this VPC's gateway endpoint.
#
# "Principal": "*" reads alarmingly, so it is worth being precise about what it does and
# does not mean. Block Public Access stays fully on and the bucket still reports
# IsPublic: false, because S3 treats a fixed aws:SourceVpce condition as a non-public
# grant — verified on 2026-08-14, where PutBucketPolicy was accepted under
# BlockPublicPolicy = true and get-bucket-policy-status returned false. Fetching a manifest
# from the public internet on the same day returned 403.
#
# What it is not: a claim that only the VPC can read this bucket. The statement is an
# Allow, and Allows are additive — IAM principals in this account keep whatever S3 access
# their own policies give them, from anywhere, exactly as with every other bucket here.
# The VPCE condition governs the anonymous grant, which is the one this file adds.
resource "aws_s3_bucket_policy" "registry" {
  count = local.registry_s3 ? 1 : 0

  bucket = aws_s3_bucket.registry[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AnonymousReadFromThisVpceOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.registry[0].arn}/*"
        Condition = {
          StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.s3.id }
        }
      },
      {
        # Same TLS floor as the client buckets. The image puller already uses HTTPS, so
        # this costs nothing and turns an assumption into an enforced condition.
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.registry[0].arn,
          "${aws_s3_bucket.registry[0].arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.registry]
}
