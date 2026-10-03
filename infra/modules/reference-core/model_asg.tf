# Phase 5: GPU ASG serving baked vLLM AMI behind the internal model ALB.
# max_size is always 1 to prevent runaway capacity.

locals {
  # Resources exist when AMI is configured; traffic switches only when desired > 0.
  model_gpu_enabled = var.model_ami_id != ""
  model_gpu_active  = local.model_gpu_enabled && var.model_asg_desired > 0
}

resource "aws_lb_target_group" "model_gpu" {
  count = local.model_gpu_enabled ? 1 : 0

  name        = "${local.name_prefix}-model-gpu"
  port        = var.model_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-gpu-tg"
    Component = "model"
  })
}

# Model plane is GPU-only (Fargate stub removed). ALB always forwards to the instance TG.
resource "aws_lb_listener" "model" {
  load_balancer_arn = aws_lb.model.arn
  port              = var.model_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.model_gpu[0].arn
  }

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-listener"
    Component = "model"
  })

  lifecycle {
    precondition {
      condition     = var.model_ami_id != ""
      error_message = "model_ami_id is required (Fargate model-stub path removed; model plane is GPU AMI only)."
    }
  }
}


resource "aws_iam_role" "model_instance" {
  count = local.model_gpu_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-model-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-ec2"
    Component = "model"
  })
}

# SSM (Session Manager) is the only interactive way into a no-NAT model subnet, and it
# needs both this attachment and the ssm/ssmmessages/ec2messages endpoints in locals.tf.
# Gated on the same variable so the two can never drift into a half-configuration: an
# endpoint with no permission (or vice versa) fails silently at debug time, which is
# exactly when you cannot afford to be debugging the debugger.
resource "aws_iam_role_policy_attachment" "model_instance_ssm" {
  count = local.model_gpu_enabled && var.model_ssm_access ? 1 : 0

  role       = aws_iam_role.model_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Without this the only signal from a failing GPU instance is "ALB target unhealthy"
# 40 minutes later. The AMI's cloudwatch-agent ships the sovran-vllm journal here via
# the Logs interface endpoint (no NAT needed). vLLM request logging is suppressed at
# the flag level in the AMI, so prompt bodies stay out of platform logs (PLAN.md §14).
resource "aws_iam_role_policy_attachment" "model_instance_cw" {
  count = local.model_gpu_enabled ? 1 : 0

  role       = aws_iam_role.model_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_cloudwatch_log_group" "model_vllm" {
  count = local.model_gpu_enabled ? 1 : 0

  # Must match the log_group baked into the AMI (packer var log_group).
  name              = "/${var.project_slug}/model/vllm"
  retention_in_days = var.model_log_retention_days

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-vllm-logs"
    Component = "model"
  })
}

resource "aws_iam_instance_profile" "model_instance" {
  count = local.model_gpu_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-model-ec2-"
  role        = aws_iam_role.model_instance[0].name

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-ec2-profile"
    Component = "model"
  })
}

resource "aws_launch_template" "model_gpu" {
  count = local.model_gpu_enabled ? 1 : 0

  name_prefix   = "${local.name_prefix}-model-gpu-"
  image_id      = var.model_ami_id
  instance_type = var.model_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.model_instance[0].arn
  }

  # Private model subnets: no public IP (no NAT on this tier either).
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.model.id]
    device_index                = 0
    delete_on_termination       = true
  }

  # Root volume from AMI snapshot. Raise gp3 throughput so EBS lazy-load of
  # baked weights (~multi-GB) is not the bottleneck on first boot.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      iops                  = 6000
      throughput            = 500
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.base_tags, {
      Name      = "${local.name_prefix}-model-gpu"
      Component = "model"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.base_tags, {
      Name      = "${local.name_prefix}-model-gpu"
      Component = "model"
    })
  }

  # AMI enables sovran-vllm on boot. Avoid a second restart race with
  # multi-user.target; only ensure the unit is enabled.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eux
    systemctl enable sovran-vllm.service || true
    # Do not restart here — enable + WantedBy=multi-user.target starts it once.
    # Restart would interrupt first-boot prewarm + load and double cold-start cost.
  EOF
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "model_gpu" {
  count = local.model_gpu_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-model-gpu-"

  # Hard cap: never more than one GPU instance for this PoC.
  min_size         = 0
  max_size         = 1
  desired_capacity = min(var.model_asg_desired, 1)

  vpc_zone_identifier = aws_subnet.model[*].id
  target_group_arns   = [aws_lb_target_group.model_gpu[0].arn]

  # "EC2" during bring-up: a slow or broken first load then leaves the instance alive
  # to be inspected over SSM instead of being replaced mid-diagnosis. "ELB" for demos.
  health_check_type = var.model_health_check_type
  # First vLLM + Gemma load can exceed 15m (weights + compile). Give 40m before
  # ELB failure replaces the only GPU instance (quota is typically one G host).
  health_check_grace_period = var.model_health_check_grace_seconds

  launch_template {
    id      = aws_launch_template.model_gpu[0].id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-model-gpu"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = var.project_slug
    propagate_at_launch = true
  }
  tag {
    key                 = "Component"
    value               = "model"
    propagate_at_launch = true
  }
  tag {
    key                 = "Client"
    value               = "platform"
    propagate_at_launch = true
  }

  # Destroy sets desired_capacity to 0 and then waits for the group to drain. The provider's
  # default for that wait is 10 minutes, which a g6.xlarge does not reliably meet: on the
  # 2026-08-14 teardown the destroy failed with
  #   waiting for Auto Scaling Group (...) drain: output = 1, want 0
  # while the instance was still "shutting-down". Nothing was wrong — the second destroy
  # completed cleanly — but a two-pass teardown trains an operator to ignore a failed
  # destroy, which is exactly the habit that leaves a GPU running overnight.
  #
  # 20m is a ceiling, not a delay: draining returns as soon as the instance is gone, so a
  # normal teardown is unaffected. Deliberately not force_delete, which returns without
  # confirming the instance actually terminated — the opposite of what a teardown needs.
  timeouts {
    delete = "20m"
  }

  lifecycle {
    create_before_destroy = true
  }
}
