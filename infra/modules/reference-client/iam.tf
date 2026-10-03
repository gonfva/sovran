resource "aws_iam_role" "task" {
  name_prefix = "${local.name_prefix}-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-task"
    Component = "agent"
  })
}

resource "aws_iam_role_policy" "task" {
  name_prefix = "${local.name_prefix}-task-"
  role        = aws_iam_role.task.id

  # concat rather than a conditional inside the list: the KMS statement must disappear
  # entirely under bucket_encryption = "AES256", and an empty-Resource statement would be
  # an invalid policy rather than a no-op.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "ListCodeBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [aws_s3_bucket.code.arn]
      },
      {
        Sid    = "ListDataBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [aws_s3_bucket.data.arn]
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "",
              "documents",
              "documents/*",
              "sessions",
              "sessions/*",
              "out",
              "out/*",
            ]
          }
        }
      },
      {
        Sid    = "GetCodeObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
        ]
        Resource = ["${aws_s3_bucket.code.arn}/*"]
      },
      {
        Sid    = "GetDataDocumentsAndSessions"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
        ]
        Resource = [
          "${aws_s3_bucket.data.arn}/documents/*",
          "${aws_s3_bucket.data.arn}/sessions/*",
          "${aws_s3_bucket.data.arn}/out/*",
        ]
      },
      {
        Sid    = "PutSessionAndOut"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "${aws_s3_bucket.data.arn}/sessions/*",
          "${aws_s3_bucket.data.arn}/out/*",
        ]
      },
      ], local.cmk_enabled ? [
      {
        # Granted but never exercised from inside the VPC: the sync containers hold no KMS
        # client and send no SSE-KMS headers. S3 performs these calls service-side against
        # this role's identity, which is why no KMS interface endpoint is needed.
        Sid    = "KmsForBuckets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = [aws_kms_key.client[0].arn]
      },
    ] : [])
  })
}
