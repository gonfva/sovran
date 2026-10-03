data "aws_caller_identity" "current" {}

resource "terraform_data" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.reference_account_id
      error_message = "AWS profile is authenticated to ${data.aws_caller_identity.current.account_id}, expected reference_account_id=${var.reference_account_id}."
    }
  }
}

module "core" {
  source = "../../modules/reference-core"

  project_slug          = var.project_slug
  region                = var.region
  vpc_cidr              = var.vpc_cidr
  az_count              = var.az_count
  endpoint_az_count     = var.endpoint_az_count
  model_ssm_access      = var.model_ssm_access
  registry_mode         = var.registry_mode
  netcheck_image_tag    = var.netcheck_image_tag
  netcheck_image_digest = var.netcheck_image_digest
  model_ami_id          = var.model_ami_id
  model_instance_type   = var.model_instance_type
  model_asg_desired     = var.model_asg_desired

  model_health_check_type          = var.model_health_check_type
  model_health_check_grace_seconds = var.model_health_check_grace_seconds

  depends_on = [terraform_data.account_guard]
}

# Per-client vertical slices (Phase 2+). Add a third client = new map entry + apply.
module "clients" {
  source   = "../../modules/reference-client"
  for_each = var.clients

  project_slug            = var.project_slug
  region                  = var.region
  client_slug             = each.value.slug
  client_account_id       = each.value.account_id
  vpc_id                  = module.core.vpc_id
  vpc_cidr                = module.core.vpc_cidr
  endpoint_subnet_ids     = module.core.endpoint_subnet_ids
  agent_subnet_ids        = module.core.agent_subnet_ids
  agent_security_group_id = module.core.agent_security_group_id
  ecs_cluster_arn         = module.core.ecs_cluster_arn
  ecs_cluster_name        = module.core.ecs_cluster_name
  ecs_execution_role_arn  = module.core.ecs_execution_role_arn
  model_base_url          = module.core.model_base_url
  model_name              = var.model_name
  bucket_encryption       = var.bucket_encryption
  agent_repository_url    = module.core.agent_repository_url
  sync_repository_url     = module.core.sync_repository_url
  agent_image_tag         = var.agent_image_tag
  sync_image_tag          = var.sync_image_tag
  agent_image_digest      = var.agent_image_digest
  sync_image_digest       = var.sync_image_digest
  agent_port              = var.agent_port
  desired_count           = var.agent_desired_count
  sync_interval_seconds   = var.sync_interval_seconds
  acceptance_required     = false
}

# Phase 2 used module.client_a; preserve state when switching to for_each.
moved {
  from = module.client_a
  to   = module.clients["a"]
}
