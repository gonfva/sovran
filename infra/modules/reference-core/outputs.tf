output "vpc_id" {
  value       = aws_vpc.this.id
  description = "Reference VPC ID."
}

output "vpc_cidr" {
  value       = aws_vpc.this.cidr_block
  description = "Reference VPC CIDR."
}

output "endpoint_subnet_ids" {
  value       = aws_subnet.endpoint[*].id
  description = "Endpoint-tier subnet IDs (VPCE ENIs, PrivateLink NLBs)."
}

output "agent_subnet_ids" {
  value       = aws_subnet.agent[*].id
  description = "Agent-tier subnet IDs."
}

output "model_subnet_ids" {
  value       = aws_subnet.model[*].id
  description = "Model-tier subnet IDs."
}

output "agent_security_group_id" {
  value       = aws_security_group.agent.id
  description = "Security group for agent tasks."
}

output "model_security_group_id" {
  value       = aws_security_group.model.id
  description = "Security group for model tasks."
}

output "model_lb_security_group_id" {
  value       = aws_security_group.model_lb.id
  description = "Security group for the internal model ALB."
}

output "vpce_security_group_id" {
  value       = aws_security_group.vpce.id
  description = "Security group on interface VPC endpoints."
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.this.name
  description = "ECS cluster name."
}

output "ecs_cluster_arn" {
  value       = aws_ecs_cluster.this.arn
  description = "ECS cluster ARN."
}

output "ecs_execution_role_arn" {
  value       = aws_iam_role.ecs_execution.arn
  description = "Shared ECS task execution role ARN."
}

output "model_lb_dns_name" {
  value       = aws_lb.model.dns_name
  description = "Internal model ALB DNS name (agent MODEL_BASE_URL host)."
}

output "model_lb_arn" {
  value       = aws_lb.model.arn
  description = "Internal model ALB ARN."
}

output "model_target_group_arn" {
  value       = try(aws_lb_target_group.model_gpu[0].arn, null)
  description = "Model GPU instance target group ARN."
}

output "model_port" {
  value       = var.model_port
  description = "Model HTTP port."
}

output "model_base_url" {
  value       = "http://${aws_lb.model.dns_name}:${var.model_port}"
  description = "Base URL agents should use for the model."
}

# These stay named *_repository_url in both modes. The value is a registry host plus a
# repository path either way, and every consumer just appends ":tag" or "@sha256:...", so
# renaming them would churn reference-client and envs/reference to say the same thing.
output "netcheck_repository_url" {
  value       = local.repository_urls["netcheck"]
  description = "Registry path for the netcheck image (ECR repo URL, or S3 registry host + repo)."
}

output "agent_repository_url" {
  value       = local.repository_urls["agent"]
  description = "Registry path for the agent image (ECR repo URL, or S3 registry host + repo)."
}

output "sync_repository_url" {
  value       = local.repository_urls["sync"]
  description = "Registry path for the sync image (ECR repo URL, or S3 registry host + repo)."
}

output "ecr_repository_urls" {
  value       = local.repository_urls
  description = "All platform image repository paths by key."
}

output "registry_mode" {
  value       = var.registry_mode
  description = "Which registry backs the images: \"ecr\" or \"s3\"."
}

output "registry_bucket" {
  value       = try(aws_s3_bucket.registry[0].bucket, null)
  description = "Registry bucket name under registry_mode = \"s3\"; null under \"ecr\". Push target for scripts/push-images-s3.py."
}

output "registry_host" {
  value       = local.registry_s3 ? local.registry_host : null
  description = "Registry hostname under registry_mode = \"s3\"; null under \"ecr\"."
}

output "netcheck_task_definition_arn" {
  value       = aws_ecs_task_definition.netcheck.arn
  description = "Task definition for Phase 1 exit netcheck (run-task in agent subnets)."
}

output "s3_gateway_endpoint_id" {
  value       = aws_vpc_endpoint.s3.id
  description = "S3 gateway VPC endpoint ID."
}

output "interface_endpoint_ids" {
  value       = { for k, ep in aws_vpc_endpoint.interface : k => ep.id }
  description = "Interface VPC endpoint IDs by logical key."
}

output "model_gpu_enabled" {
  value       = local.model_gpu_enabled
  description = "True when model_ami_id is set and GPU ASG resources exist."
}

output "model_asg_name" {
  value       = try(aws_autoscaling_group.model_gpu[0].name, null)
  description = "Model GPU ASG name (null if disabled)."
}

output "model_log_group" {
  value       = try(aws_cloudwatch_log_group.model_vllm[0].name, null)
  description = "CloudWatch group receiving the vLLM journal (aws logs tail <this> --follow)."
}

output "model_gpu_target_group_arn" {
  value       = try(aws_lb_target_group.model_gpu[0].arn, null)
  description = "Instance target group for GPU model (null if disabled)."
}

output "model_ami_id" {
  value       = var.model_ami_id != "" ? var.model_ami_id : null
  description = "Configured model AMI ID."
}
