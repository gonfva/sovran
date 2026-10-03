resource "aws_cloudwatch_log_group" "agent" {
  name              = "/${var.project_slug}/agent/${var.client_slug}"
  retention_in_days = 14

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-logs"
    Component = "agent"
  })
}

resource "aws_ecs_task_definition" "agent" {
  family                   = "${local.name_prefix}-agent"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.agent_cpu
  memory                   = var.agent_memory
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "workspace"
  }

  container_definitions = jsonencode([
    {
      name      = "sync-down"
      image     = local.sync_image
      essential = false
      command   = ["python", "-u", "sync_down.py"]
      environment = [
        { name = "WORKSPACE", value = "/workspace" },
        { name = "CODE_BUCKET", value = aws_s3_bucket.code.id },
        { name = "DATA_BUCKET", value = aws_s3_bucket.data.id },
        { name = "AWS_REGION", value = var.region },
        { name = "AWS_DEFAULT_REGION", value = var.region },
        { name = "CLIENT_SLUG", value = var.client_slug },
      ]
      mountPoints = [
        {
          sourceVolume  = "workspace"
          containerPath = "/workspace"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "sync-down"
        }
      }
    },
    {
      name      = "agent"
      image     = local.agent_image
      essential = true
      dependsOn = [
        {
          containerName = "sync-down"
          condition     = "SUCCESS"
        }
      ]
      portMappings = [
        {
          containerPort = var.agent_port
          hostPort      = var.agent_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "PORT", value = tostring(var.agent_port) },
        { name = "HOST", value = "0.0.0.0" },
        { name = "WORKSPACE", value = "/workspace" },
        { name = "CLIENT_SLUG", value = var.client_slug },
        { name = "MODEL_BASE_URL", value = var.model_base_url },
        # Must match the id vLLM actually serves, which is the --model path baked into the
        # AMI. The agent image still defaults to "sovran-stub" from the removed Fargate
        # stub; leaving it unset makes every completion fail 404 "model does not exist"
        # while /health, PrivateLink and the S3 sync all still look healthy.
        { name = "MODEL_NAME", value = var.model_name },
      ]
      mountPoints = [
        {
          sourceVolume  = "workspace"
          containerPath = "/workspace"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "agent"
        }
      }
    },
    {
      name      = "sync-up"
      image     = local.sync_image
      essential = false
      dependsOn = [
        {
          containerName = "sync-down"
          condition     = "SUCCESS"
        }
      ]
      command = ["python", "-u", "sync_up.py"]
      environment = [
        { name = "WORKSPACE", value = "/workspace" },
        { name = "DATA_BUCKET", value = aws_s3_bucket.data.id },
        { name = "AWS_REGION", value = var.region },
        { name = "AWS_DEFAULT_REGION", value = var.region },
        { name = "CLIENT_SLUG", value = var.client_slug },
        { name = "SYNC_INTERVAL_SECONDS", value = tostring(var.sync_interval_seconds) },
      ]
      mountPoints = [
        {
          sourceVolume  = "workspace"
          containerPath = "/workspace"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "sync-up"
        }
      }
    },
  ])

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent"
    Component = "agent"
  })
}

resource "aws_ecs_service" "agent" {
  name            = "${local.name_prefix}-agent"
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.agent.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.agent_subnet_ids
    security_groups  = [var.agent_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.agent.arn
    container_name   = "agent"
    container_port   = var.agent_port
  }

  depends_on = [
    aws_lb_listener.agent,
    aws_s3_object.code_readme,
    aws_s3_object.data_hello,
  ]

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent"
    Component = "agent"
  })
}
