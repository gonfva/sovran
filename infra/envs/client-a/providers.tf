provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_slug
      ManagedBy = "terraform"
      Env       = "client-a"
      Client    = var.client_slug
    }
  }
}
