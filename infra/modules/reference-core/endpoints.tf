# Gateway endpoint for S3 (ECR image layers + the per-client buckets). No NAT required.
#
# S3 is the one egress an agent on the no-NAT tiers can actually reach, so an unpolicied
# gateway is the widest hole in the design: it permits every bucket in the partition,
# including an attacker-controlled one that allows our principals. The policy below closes
# that to our own buckets — see var.s3_endpoint_policy for why it cannot close completely
# until the ECR dependency goes away (PLAN.md Phase 8).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.endpoint.id,
    aws_route_table.agent.id,
    aws_route_table.model.id,
  ]

  policy = var.s3_endpoint_policy ? jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        # Our own buckets, matched by the naming convention rather than by ARN: they are
        # created in reference-client, which consumes this module's outputs, so naming
        # them here would be a dependency cycle. The Phase 8 registry bucket is named to
        # this same pattern precisely so it needs no statement of its own.
        Sid       = "OwnBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          "arn:aws:s3:::${var.project_slug}-${data.aws_caller_identity.current.account_id}-*",
          "arn:aws:s3:::${var.project_slug}-${data.aws_caller_identity.current.account_id}-*/*",
        ]
      },
      ],
      # Phase 8.2. Under registry_mode = "s3" this statement is gone and the policy names
      # only buckets this account owns — which is the whole point of Phase 8, more than the
      # ~$32/month. S3 is the one egress an injected agent can still reach, so the
      # difference between "we do not route to the internet" and "the data plane rejects
      # anything off-path" is exactly this list.
      [for s in [
        {
          # ECR stores image layers in an AWS-owned bucket, and a Fargate pull fetches them
          # straight through this endpoint. Deny it and every task start fails with
          # CannotPullContainerError. A bucket we cannot inspect or reason about, sitting
          # inside our only egress.
          Sid       = "EcrLayers"
          Effect    = "Allow"
          Principal = "*"
          Action    = ["s3:GetObject"]
          Resource  = ["arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*"]
        },
    ] : s if !local.registry_s3])
  }) : null

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-s3-gw"
    Component = "network"
  })
}

# Interface endpoints in endpoint subnets (private DNS enabled).
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = slice(aws_subnet.endpoint[*].id, 0, var.endpoint_az_count)
  security_group_ids  = [aws_security_group.vpce.id]

  tags = merge(local.base_tags, {
    Name      = "${local.name_prefix}-${replace(each.value, ".", "-")}"
    Component = "network"
  })
}
