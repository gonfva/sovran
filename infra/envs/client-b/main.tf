data "aws_caller_identity" "current" {}

resource "terraform_data" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.client_account_id
      error_message = "AWS profile is authenticated to ${data.aws_caller_identity.current.account_id}, expected client_account_id=${var.client_account_id}."
    }
  }
}

module "client" {
  source = "../../modules/client"

  project_slug          = var.project_slug
  region                = var.region
  client_slug           = var.client_slug
  vpc_cidr              = var.vpc_cidr
  endpoint_service_name = var.endpoint_service_name
  agent_port            = var.agent_port
  instance_type         = var.instance_type

  depends_on = [terraform_data.account_guard]
}
