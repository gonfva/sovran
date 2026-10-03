data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  name_prefix = "${var.project_slug}-${var.client_slug}"
  az          = data.aws_availability_zones.available.names[0]

  base_tags = merge(
    {
      Project   = var.project_slug
      Client    = var.client_slug
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-vpc"
    Component = "network"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-igw"
    Component = "network"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-public"
    Component = "network"
    Tier      = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-public-rt"
    Component = "network"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  description = "Client admin EC2 (no inbound; SSM only)"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-ec2-sg"
    Component = "client"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# No inbound rules (SSM via SSM service endpoints over outbound HTTPS).
resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  security_group_id = aws_security_group.ec2.id
  description       = "PoC-open outbound for SSM and HTTPS"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "vpce" {
  name_prefix = "${local.name_prefix}-vpce-"
  description = "Interface endpoint to reference agent endpoint service"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-vpce-sg"
    Component = "endpoint"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_ec2" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "Agent port from client EC2"
  ip_protocol                  = "tcp"
  from_port                    = var.agent_port
  to_port                      = var.agent_port
  referenced_security_group_id = aws_security_group.ec2.id
}

resource "aws_vpc_security_group_egress_rule" "vpce_egress" {
  security_group_id = aws_security_group.vpce.id
  description       = "Return path for PrivateLink"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_endpoint" "agent" {
  vpc_id              = aws_vpc.this.id
  service_name        = var.endpoint_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.public.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = false

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-vpce"
    Component = "endpoint"
  })
}

resource "aws_iam_role" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-ec2"
    Component = "client"
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  role        = aws_iam_role.ec2.name

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-ec2-profile"
    Component = "client"
  })
}

resource "aws_instance" "admin" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # No SSH key — SSM only.
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    hostnamectl set-hostname "${local.name_prefix}-admin"
    # Ensure SSM agent is present (AL2023 includes it); restart for safety.
    systemctl enable amazon-ssm-agent || true
    systemctl restart amazon-ssm-agent || true
    dnf install -y curl-minimal || yum install -y curl || true
  EOF

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-admin"
    Component = "client"
  })
}
