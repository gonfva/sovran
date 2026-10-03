resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-ref"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-ref-cluster"
    Component = "platform"
  })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

resource "aws_cloudwatch_log_group" "netcheck" {
  name              = "/${local.name_prefix}/netcheck"
  retention_in_days = 7

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-netcheck-logs"
    Component = "platform"
  })
}

resource "aws_lb" "model" {
  name               = "${local.name_prefix}-model"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.model_lb.id]
  subnets            = aws_subnet.model[*].id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-alb"
    Component = "model"
  })
}

# Listener is defined in model_asg.tf (GPU instance target group only; Fargate stub removed).

locals {
  # Digest wins over tag when both are given, in either registry mode — ECR serves digest
  # pulls too, so this is not an S3 special case. Pinning is the recommendation rather than
  # the requirement because requiring it would make the first apply of a fresh registry
  # impossible: the bucket has to exist before anything can be pushed to it, and the digest
  # only exists after the push. Tag first, pin second.
  netcheck_image = var.netcheck_image_digest != "" ? "${local.repository_urls["netcheck"]}@${var.netcheck_image_digest}" : "${local.repository_urls["netcheck"]}:${var.netcheck_image_tag}"
}

# One-shot task definition for Phase 1 exit checks (run via aws ecs run-task).
resource "aws_ecs_task_definition" "netcheck" {
  family                   = "${local.name_prefix}-netcheck"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.netcheck_task.arn

  container_definitions = jsonencode([
    {
      name      = "netcheck"
      image     = local.netcheck_image
      essential = true
      environment = [
        {
          name  = "MODEL_HEALTH_URL"
          value = "http://${aws_lb.model.dns_name}:${var.model_port}/health"
        },
        {
          name  = "INTERNET_URL"
          value = "https://example.com"
        },
        {
          name  = "EXPECTED_HOSTS"
          value = join(" ", local.netcheck_expected_hosts)
        },
        {
          name  = "BLOCKED_HOSTS"
          value = join(" ", local.netcheck_blocked_hosts)
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.netcheck.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "netcheck"
        }
      }
    }
  ])

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-netcheck"
    Component = "platform"
  })
}
