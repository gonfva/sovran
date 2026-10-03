# Shared SG for interface VPC endpoints (HTTPS from agent + model tiers).
resource "aws_security_group" "vpce" {
  name_prefix = "${local.name_prefix}-vpce-"
  description = "Interface VPC endpoints (ECR, Logs, and SSM when model_ssm_access)"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-vpce-sg"
    Component = "network"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "model" {
  name_prefix = "${local.name_prefix}-model-"
  description = "Model plane tasks and internal model LB targets"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-sg"
    Component = "model"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "agent" {
  name_prefix = "${local.name_prefix}-agent-"
  description = "Agent plane tasks (ingress from NLB added in Phase 2)"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-sg"
    Component = "agent"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "model_lb" {
  name_prefix = "${local.name_prefix}-model-lb-"
  description = "Internal model application load balancer"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-lb-sg"
    Component = "model"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# --- VPC endpoints ---
resource "aws_vpc_security_group_ingress_rule" "vpce_from_agent" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "HTTPS from agent tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.agent.id
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_model" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "HTTPS from model tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.model.id
}

resource "aws_vpc_security_group_egress_rule" "vpce_egress_all" {
  security_group_id = aws_security_group.vpce.id
  description       = "Allow return traffic from AWS services"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Model LB: agents call model only via the internal LB ---
resource "aws_vpc_security_group_ingress_rule" "model_lb_from_agent" {
  security_group_id            = aws_security_group.model_lb.id
  description                  = "HTTP from agent tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.model_port
  to_port                      = var.model_port
  referenced_security_group_id = aws_security_group.agent.id
}

resource "aws_vpc_security_group_egress_rule" "model_lb_to_model" {
  security_group_id            = aws_security_group.model_lb.id
  description                  = "Forward to model tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.model_port
  to_port                      = var.model_port
  referenced_security_group_id = aws_security_group.model.id
}

# --- Model tasks ---
resource "aws_vpc_security_group_ingress_rule" "model_from_lb" {
  security_group_id            = aws_security_group.model.id
  description                  = "HTTP from internal model LB"
  ip_protocol                  = "tcp"
  from_port                    = var.model_port
  to_port                      = var.model_port
  referenced_security_group_id = aws_security_group.model_lb.id
}

resource "aws_vpc_security_group_egress_rule" "model_to_vpce" {
  security_group_id            = aws_security_group.model.id
  description                  = "HTTPS to interface VPC endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpce.id
}

# S3 gateway endpoint is prefix-list based; allow HTTPS to VPC CIDR + prefix later via 443 open to S3 PL.
# For ECR layers via S3 gateway, egress to S3 prefix list is required.
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

resource "aws_vpc_security_group_egress_rule" "model_to_s3" {
  security_group_id = aws_security_group.model.id
  description       = "HTTPS to S3 via gateway endpoint (ECR layers)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.s3.id
}

# --- Agent tasks ---
# Ingress from per-client NLB is added in Phase 2 (reference-client).

resource "aws_vpc_security_group_egress_rule" "agent_to_model_lb" {
  security_group_id            = aws_security_group.agent.id
  description                  = "HTTP to internal model LB"
  ip_protocol                  = "tcp"
  from_port                    = var.model_port
  to_port                      = var.model_port
  referenced_security_group_id = aws_security_group.model_lb.id
}

resource "aws_vpc_security_group_egress_rule" "agent_to_vpce" {
  security_group_id            = aws_security_group.agent.id
  description                  = "HTTPS to interface VPC endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpce.id
}

resource "aws_vpc_security_group_egress_rule" "agent_to_s3" {
  security_group_id = aws_security_group.agent.id
  description       = "HTTPS to S3 via gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.s3.id
}
