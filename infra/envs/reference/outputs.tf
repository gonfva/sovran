output "vpc_id" {
  value = module.core.vpc_id
}

output "endpoint_subnet_ids" {
  value = module.core.endpoint_subnet_ids
}

output "agent_subnet_ids" {
  value = module.core.agent_subnet_ids
}

output "model_subnet_ids" {
  value = module.core.model_subnet_ids
}

output "agent_security_group_id" {
  value = module.core.agent_security_group_id
}

output "ecs_cluster_name" {
  value = module.core.ecs_cluster_name
}

output "ecs_cluster_arn" {
  value = module.core.ecs_cluster_arn
}

output "ecs_execution_role_arn" {
  value = module.core.ecs_execution_role_arn
}

output "model_base_url" {
  value = module.core.model_base_url
}

output "model_lb_dns_name" {
  value = module.core.model_lb_dns_name
}

output "model_port" {
  value = module.core.model_port
}

output "model_gpu_enabled" {
  value = module.core.model_gpu_enabled
}

output "model_asg_name" {
  value = module.core.model_asg_name
}

output "model_log_group" {
  value = module.core.model_log_group
}

output "model_ami_id" {
  value = module.core.model_ami_id
}

output "model_target_group_arn" {
  value = module.core.model_target_group_arn
}

output "netcheck_repository_url" {
  value = module.core.netcheck_repository_url
}

output "agent_repository_url" {
  value = module.core.agent_repository_url
}

output "sync_repository_url" {
  value = module.core.sync_repository_url
}

output "netcheck_task_definition_arn" {
  value = module.core.netcheck_task_definition_arn
}

output "interface_endpoint_ids" {
  value = module.core.interface_endpoint_ids
}

# Surfaced at env level for Phase 8: the registry bucket policy gates reads on
# aws:SourceVpce = this id, which is what lets an anonymous-read bucket stay unreachable
# from anywhere but this VPC. Also the value to paste into a scratch-bucket policy when
# re-running the 8.0 spike by hand.
output "s3_gateway_endpoint_id" {
  value = module.core.s3_gateway_endpoint_id
}

# All clients (keyed by map key, e.g. "a", "b")
output "clients" {
  description = "Per-client reference outputs (buckets, EPS, task role, etc.)."
  value = {
    for k, m in module.clients : k => {
      slug                  = m.client_slug
      code_bucket           = m.code_bucket_name
      data_bucket           = m.data_bucket_name
      endpoint_service_name = m.endpoint_service_name
      agent_service_name    = m.agent_service_name
      agent_port            = m.agent_port
      kms_key_arn           = m.kms_key_arn
      log_group_name        = m.log_group_name
      task_role_arn         = m.task_role_arn
    }
  }
}

# Convenience aliases (Phase 2/docs)
output "client_a_slug" {
  value = try(module.clients["a"].client_slug, null)
}

output "client_a_code_bucket" {
  value = try(module.clients["a"].code_bucket_name, null)
}

output "client_a_data_bucket" {
  value = try(module.clients["a"].data_bucket_name, null)
}

output "client_a_endpoint_service_name" {
  value = try(module.clients["a"].endpoint_service_name, null)
}

output "client_a_agent_service_name" {
  value = try(module.clients["a"].agent_service_name, null)
}

output "client_a_agent_port" {
  value = try(module.clients["a"].agent_port, null)
}

output "client_a_kms_key_arn" {
  value = try(module.clients["a"].kms_key_arn, null)
}

output "client_a_log_group_name" {
  value = try(module.clients["a"].log_group_name, null)
}

output "client_a_task_role_arn" {
  value = try(module.clients["a"].task_role_arn, null)
}

output "client_b_slug" {
  value = try(module.clients["b"].client_slug, null)
}

output "client_b_code_bucket" {
  value = try(module.clients["b"].code_bucket_name, null)
}

output "client_b_data_bucket" {
  value = try(module.clients["b"].data_bucket_name, null)
}

output "client_b_endpoint_service_name" {
  value = try(module.clients["b"].endpoint_service_name, null)
}

output "client_b_agent_service_name" {
  value = try(module.clients["b"].agent_service_name, null)
}

output "client_b_agent_port" {
  value = try(module.clients["b"].agent_port, null)
}

output "client_b_kms_key_arn" {
  value = try(module.clients["b"].kms_key_arn, null)
}

output "client_b_log_group_name" {
  value = try(module.clients["b"].log_group_name, null)
}

output "client_b_task_role_arn" {
  value = try(module.clients["b"].task_role_arn, null)
}
