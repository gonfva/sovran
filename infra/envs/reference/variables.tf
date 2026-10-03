variable "region" {
  type        = string
  description = "AWS region (must match operator config)."
}

variable "aws_profile" {
  type        = string
  description = "AWS CLI profile for the reference account."
}

variable "project_slug" {
  type        = string
  description = "Resource name prefix."
  default     = "sovran"
}

variable "reference_account_id" {
  type        = string
  description = "Expected 12-digit reference account ID (sanity check)."
}

variable "vpc_cidr" {
  type        = string
  description = "Reference VPC CIDR."
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of AZs for subnet tiers."
  default     = 2
}

variable "endpoint_az_count" {
  type        = number
  description = "How many AZs get interface-endpoint ENIs. Billed per ENI (~$8/AZ/month each), and need not match az_count. Minimum 2."
  default     = 2
}

variable "model_ssm_access" {
  type        = bool
  description = "Create the SSM endpoint trio and grant the model instance role SSM. Set true in the same apply as model_asg_desired=1 for a new or unvalidated AMI."
  default     = false
}

variable "netcheck_image_tag" {
  type        = string
  description = "Tag of the netcheck image. Ignored when netcheck_image_digest is set."
  default     = "latest"
}

variable "netcheck_image_digest" {
  type        = string
  description = "Optional sha256:... digest pinning the netcheck image."
  default     = ""
}

# See modules/reference-core/variables.tf for the full rationale and the measured evidence.
variable "registry_mode" {
  type        = string
  description = "\"s3\" (default) serves images from a VPCE-gated bucket and drops both ECR endpoints; \"ecr\" is the fallback."
  default     = "s3"
}

variable "model_ami_id" {
  type        = string
  description = "Packer-built AMI with vLLM + baked Gemma (required; Fargate stub removed)."
}

variable "model_instance_type" {
  type    = string
  default = "g5.xlarge"
}

variable "model_asg_desired" {
  type        = number
  description = "GPU ASG desired capacity (0 or 1; max is always 1)."
  default     = 0
}

variable "model_health_check_type" {
  type        = string
  description = "ELB for demos; EC2 during first GPU bring-up so a failed load survives for SSM inspection."
  default     = "ELB"
}

variable "model_health_check_grace_seconds" {
  type        = number
  description = "Grace before health checks may replace the GPU instance."
  default     = 2400
}

variable "bucket_encryption" {
  type        = string
  description = "Default encryption for every client's buckets: aws:kms (per-client CMK, the isolation story) or AES256 (SSE-S3, no key). CREATE-TIME — changing it on a live stack orphans existing objects. See reference-client/variables.tf."
  default     = "aws:kms"
}

variable "clients" {
  type = map(object({
    slug       = string
    account_id = string
  }))
  description = "Map of clients to provision in the reference account. Add a client = new key + apply."
}

variable "agent_image_tag" {
  type    = string
  default = "latest"
}

variable "sync_image_tag" {
  type    = string
  default = "latest"
}

# Emitted by scripts/push-images-s3.py. Recommended once the images are pushed: under
# registry_mode = "s3" a digest is the only reference the client can verify, since S3
# cannot send the Docker-Content-Digest header that makes tag resolution trustworthy.
variable "agent_image_digest" {
  type    = string
  default = ""
}

variable "sync_image_digest" {
  type    = string
  default = ""
}

variable "agent_port" {
  type    = number
  default = 8080
}

variable "agent_desired_count" {
  type    = number
  default = 1
}

variable "sync_interval_seconds" {
  type    = number
  default = 30
}

variable "model_name" {
  type        = string
  description = <<-DESC
    Model id the agent sends to the model LB. vLLM serves the model under the --model
    path baked into the AMI, so this must be that path. Verify against the live server:
      curl -s http://<model_lb>:8000/v1/models | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])'
  DESC
  default     = "/opt/sovran/models/gemma-4-E2B-it"
}
