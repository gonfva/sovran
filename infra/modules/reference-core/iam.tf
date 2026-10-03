data "aws_caller_identity" "current" {}

resource "aws_iam_role" "ecs_execution" {
  name_prefix = "${local.name_prefix}-ecs-exec-"

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
    Name      = "${local.name_prefix}-ecs-execution"
    Component = "platform"
  })
}

resource "aws_iam_role_policy" "ecs_execution" {
  name_prefix = "${local.name_prefix}-ecs-exec-"
  role        = aws_iam_role.ecs_execution.id

  # The ECR statements are absent, not empty, under registry_mode = "s3". They are replaced
  # by nothing at all: an S3 registry pull is anonymous, so the execution role needs no
  # permission to perform it. A real least-privilege win, not a relocation of the grant.
  #
  # Filtered with `for ... if` rather than `local.registry_s3 ? [] : [...]` because the two
  # branches of a conditional must unify to one type, and an empty tuple does not unify with
  # a tuple of two differently-shaped objects.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([for s in [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = [for r in aws_ecr_repository.this : r.arn]
      },
      ] : s if !local.registry_s3], [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        # Shared + per-client log groups under /${project_slug}/...
        Resource = [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${local.name_prefix}/*:*",
        ]
      },
    ])
  })
}

resource "aws_iam_role" "netcheck_task" {
  name_prefix = "${local.name_prefix}-netcheck-task-"

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
    Name      = "${local.name_prefix}-netcheck-task"
    Component = "platform"
  })
}
