resource "aws_lb" "agent" {
  name                             = "${local.name_prefix}-agent"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.endpoint_subnet_ids
  security_groups                  = [aws_security_group.nlb.id]
  enable_cross_zone_load_balancing = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-nlb"
    Component = "endpoint"
  })
}

resource "aws_lb_target_group" "agent" {
  name        = "${local.name_prefix}-agent"
  port        = var.agent_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
  }

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-tg"
    Component = "endpoint"
  })
}

resource "aws_lb_listener" "agent" {
  load_balancer_arn = aws_lb.agent.arn
  port              = var.agent_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-listener"
    Component = "endpoint"
  })
}

resource "aws_vpc_endpoint_service" "agent" {
  acceptance_required        = var.acceptance_required
  network_load_balancer_arns = [aws_lb.agent.arn]
  allowed_principals         = ["arn:aws:iam::${var.client_account_id}:root"]
  supported_ip_address_types = ["ipv4"]

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-eps"
    Component = "endpoint"
  })
}
