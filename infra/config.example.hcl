# Sovran PoC — operator configuration (example)
#
# Copy to config.hcl (gitignored) and fill in real values:
#   cp config.example.hcl config.hcl
#
# Profile names must match entries in ~/.aws/credentials (or ~/.aws/config).
# Never commit real account credentials or long-lived keys.

region         = "eu-west-1"
project_slug   = "sovran"

# AWS CLI profile names used by Terraform providers and operator scripts.
# Defaults match PLAN.md §11; override if your local profile names differ.
profiles = {
  reference = "sovran-ref"
  client_a  = "sovran-client-a"
  client_b  = "sovran-client-b"
}

# Account IDs for the three pre-existing accounts (12-digit strings).
# Confirm with: aws sts get-caller-identity --profile <name>
reference_account_id = "111111111111"

clients = {
  a = {
    slug       = "alpha"
    account_id = "222222222222"
  }
  b = {
    slug       = "beta"
    account_id = "333333333333"
  }
}

# Optional overrides (leave commented until a later phase needs them)
# image_tags = {
#   agent      = "latest"
#   sync       = "latest"
#   model_stub = "latest"
# }
# model_ami_id = "ami-..."   # from packer build; set in envs/reference/terraform.tfvars

# Hugging Face: do NOT put tokens in git. For Packer AMI builds use:
#   export HF_TOKEN=hf_...
# (Packer reads HF_TOKEN / HUGGING_FACE_HUB_TOKEN; see packer/README.md)

