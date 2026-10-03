variable "project_slug" {
  type = string
}

variable "region" {
  type = string
}

variable "client_slug" {
  type        = string
  description = "Short client id used in names/tags (e.g. alpha)."
}

variable "client_account_id" {
  type        = string
  description = "12-digit AWS account ID allowed to connect to this client's endpoint service."
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  description = "Reference VPC CIDR (used sparingly for NLB/health paths if needed)."
}

variable "endpoint_subnet_ids" {
  type        = list(string)
  description = "Subnets for PrivateLink NLB."
}

variable "agent_subnet_ids" {
  type        = list(string)
  description = "Subnets for agent Fargate tasks."
}

variable "agent_security_group_id" {
  type        = string
  description = "Shared agent-tier security group from reference-core."
}

variable "ecs_cluster_arn" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_execution_role_arn" {
  type = string
}

variable "model_base_url" {
  type        = string
  description = "Internal model URL for agent MODEL_BASE_URL."
}

variable "model_name" {
  type        = string
  description = "Model id the agent sends in /v1/chat/completions. Must equal the id vLLM serves (the --model path baked into the AMI), not the retired stub name."
}

variable "bucket_encryption" {
  type        = string
  description = <<-DESC
    Default encryption for this client's code and data buckets. "aws:kms" creates a
    per-client CMK — a second, independent authorization boundary on top of the bucket
    policy, and the isolation story in PLAN.md. "AES256" uses SSE-S3 and creates no key.

    Not an endpoint-cost lever: SSE-KMS is decrypted inside S3, so neither setting needs a
    KMS interface endpoint (see reference-core/locals.tf). The ~$1/month saving is not the
    point; a faster teardown/rebuild loop is.

    CREATE-TIME CHOICE. Flipping a live stack to AES256 re-encrypts nothing — existing
    objects keep referencing the CMK Terraform is about to destroy, and the task role
    loses kms:Decrypt in the same apply, so sync-down fails immediately and the objects
    become unreadable for good after the 7-day window. Destroy the buckets first.
  DESC
  default     = "aws:kms"

  validation {
    condition     = contains(["aws:kms", "AES256"], var.bucket_encryption)
    error_message = "bucket_encryption must be aws:kms or AES256."
  }
}

variable "agent_repository_url" {
  type = string
}

variable "sync_repository_url" {
  type = string
}

variable "agent_image_tag" {
  type        = string
  description = "Ignored when agent_image_digest is set."
  default     = "latest"
}

variable "sync_image_tag" {
  type        = string
  description = "Ignored when sync_image_digest is set."
  default     = "latest"
}

variable "agent_image_digest" {
  type        = string
  description = "Optional sha256:... digest pinning the agent image, overriding agent_image_tag."
  default     = ""

  validation {
    condition     = var.agent_image_digest == "" || startswith(var.agent_image_digest, "sha256:")
    error_message = "agent_image_digest must be empty or a full sha256:... digest."
  }
}

variable "sync_image_digest" {
  type        = string
  description = "Optional sha256:... digest pinning the sync image, overriding sync_image_tag."
  default     = ""

  validation {
    condition     = var.sync_image_digest == "" || startswith(var.sync_image_digest, "sha256:")
    error_message = "sync_image_digest must be empty or a full sha256:... digest."
  }
}

variable "agent_port" {
  type    = number
  default = 8080
}

variable "agent_cpu" {
  type    = number
  default = 512
}

variable "agent_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "sync_interval_seconds" {
  type    = number
  default = 30
}

variable "acceptance_required" {
  type        = bool
  description = "If true, endpoint connections must be accepted (Terraform accepter can handle)."
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
