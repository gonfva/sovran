output "client_slug" {
  value = var.client_slug
}

output "kms_key_arn" {
  value       = try(aws_kms_key.client[0].arn, null)
  description = "Null when bucket_encryption = AES256 (no CMK is created)."
}

output "kms_key_id" {
  value = try(aws_kms_key.client[0].key_id, null)
}

output "bucket_encryption" {
  value       = var.bucket_encryption
  description = "Which default encryption the client buckets were created with. Create-time; see variables.tf."
}

output "code_bucket_name" {
  value = aws_s3_bucket.code.id
}

output "data_bucket_name" {
  value = aws_s3_bucket.data.id
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "agent_service_name" {
  value = aws_ecs_service.agent.name
}

output "agent_task_definition_arn" {
  value = aws_ecs_task_definition.agent.arn
}

output "nlb_arn" {
  value = aws_lb.agent.arn
}

output "nlb_dns_name" {
  value = aws_lb.agent.dns_name
}

output "endpoint_service_name" {
  value       = aws_vpc_endpoint_service.agent.service_name
  description = "PrivateLink service name for the client account VPCE."
}

output "endpoint_service_id" {
  value = aws_vpc_endpoint_service.agent.id
}

output "agent_port" {
  value = var.agent_port
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.agent.name
}
