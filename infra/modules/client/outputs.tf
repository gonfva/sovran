output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "ec2_instance_id" {
  value = aws_instance.admin.id
}

output "ec2_private_ip" {
  value = aws_instance.admin.private_ip
}

output "ec2_public_ip" {
  value = aws_instance.admin.public_ip
}

output "vpc_endpoint_id" {
  value = aws_vpc_endpoint.agent.id
}

output "vpc_endpoint_dns_entries" {
  value = aws_vpc_endpoint.agent.dns_entry
}

output "agent_url" {
  description = "HTTP base URL for the agent via PrivateLink (use first DNS name)."
  value = length(aws_vpc_endpoint.agent.dns_entry) > 0 ? (
    "http://${aws_vpc_endpoint.agent.dns_entry[0].dns_name}:${var.agent_port}"
  ) : null
}

output "agent_port" {
  value = var.agent_port
}
