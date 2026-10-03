output "vpc_id" {
  value = module.client.vpc_id
}

output "ec2_instance_id" {
  value = module.client.ec2_instance_id
}

output "ec2_public_ip" {
  value = module.client.ec2_public_ip
}

output "vpc_endpoint_id" {
  value = module.client.vpc_endpoint_id
}

output "vpc_endpoint_dns_entries" {
  value = module.client.vpc_endpoint_dns_entries
}

output "agent_url" {
  value = module.client.agent_url
}

output "agent_port" {
  value = module.client.agent_port
}
