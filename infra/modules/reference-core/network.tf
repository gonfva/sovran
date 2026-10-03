data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-ref-vpc"
    Component = "network"
  })
}

resource "aws_subnet" "endpoint" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.endpoint_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-endpoint-${count.index}"
    Component = "network"
    Tier      = "endpoint"
  })
}

resource "aws_subnet" "agent" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.agent_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-${count.index}"
    Component = "network"
    Tier      = "agent"
  })
}

resource "aws_subnet" "model" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.model_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-${count.index}"
    Component = "network"
    Tier      = "model"
  })
}

# No IGW / NAT: agent + model + endpoint tiers stay private.
resource "aws_route_table" "endpoint" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-endpoint-rt"
    Component = "network"
    Tier      = "endpoint"
  })
}

resource "aws_route_table" "agent" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-agent-rt"
    Component = "network"
    Tier      = "agent"
  })
}

resource "aws_route_table" "model" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-model-rt"
    Component = "network"
    Tier      = "model"
  })
}

resource "aws_route_table_association" "endpoint" {
  count = var.az_count

  subnet_id      = aws_subnet.endpoint[count.index].id
  route_table_id = aws_route_table.endpoint.id
}

resource "aws_route_table_association" "agent" {
  count = var.az_count

  subnet_id      = aws_subnet.agent[count.index].id
  route_table_id = aws_route_table.agent.id
}

resource "aws_route_table_association" "model" {
  count = var.az_count

  subnet_id      = aws_subnet.model[count.index].id
  route_table_id = aws_route_table.model.id
}
