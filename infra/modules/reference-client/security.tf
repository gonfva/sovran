# NLB security group (NLB with SG support) — only source into agent tasks.
resource "aws_security_group" "nlb" {
  name_prefix = "${local.name_prefix}-nlb-"
  description = "PrivateLink NLB for client ${var.client_slug} agent"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-nlb-sg"
    Component = "endpoint"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# PrivateLink consumers reach the NLB; allow all VPC-external traffic on agent port.
# (Endpoint ENIs are outside this VPC; NLB SG ingress must accept client path.)
resource "aws_vpc_security_group_ingress_rule" "nlb_agent_port" {
  security_group_id = aws_security_group.nlb.id
  description       = "Agent HTTP via PrivateLink"
  ip_protocol       = "tcp"
  from_port         = var.agent_port
  to_port           = var.agent_port
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_agent" {
  security_group_id            = aws_security_group.nlb.id
  description                  = "Forward to agent tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.agent_port
  to_port                      = var.agent_port
  referenced_security_group_id = var.agent_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "agent_from_nlb" {
  security_group_id            = var.agent_security_group_id
  description                  = "HTTP from client ${var.client_slug} NLB"
  ip_protocol                  = "tcp"
  from_port                    = var.agent_port
  to_port                      = var.agent_port
  referenced_security_group_id = aws_security_group.nlb.id
}
