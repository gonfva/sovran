variable "project_slug" {
  type        = string
  description = "Short resource name prefix (e.g. sovran)."
}

variable "region" {
  type        = string
  description = "AWS region for the reference VPC."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR for the reference VPC."
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of AZs (≥2 for Fargate practicality)."
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2."
  }
}

variable "endpoint_az_count" {
  type        = number
  description = <<-DESC
    How many endpoint subnets get an interface-endpoint ENI. Endpoints are billed per ENI
    per hour (~$8/AZ/month each in eu-west-1), so this is the largest idle-cost lever in
    the module. Endpoint ENIs do not need to follow az_count — that is 3 only because g5
    capacity forced the model tier into a third AZ (README Phase 5), and private DNS
    resolves the regional name to an ENI in any AZ.

    Floor of 2 is deliberate: a single ENI makes one AZ a hard dependency for image pulls
    and log shipping, which is not a trade this project makes for ~$8/month.
  DESC
  default     = 2

  validation {
    condition     = var.endpoint_az_count >= 2 && var.endpoint_az_count <= var.az_count
    error_message = "endpoint_az_count must be between 2 and az_count."
  }
}

variable "model_ssm_access" {
  type        = bool
  description = <<-DESC
    Create the ssm/ssmmessages/ec2messages endpoints and attach AmazonSSMManagedInstanceCore
    to the model instance role. Session Manager is the only shell into a no-NAT model
    subnet, but nothing uses it at runtime — it is purely a bring-up tool, and it is three
    of the module's endpoints (~$48/month at endpoint_az_count=2).

    Set true in the SAME apply as model_asg_desired=1 for any new or unvalidated AMI:
    enabling it afterwards on a live GPU is best-effort, and terminating the instance to
    fix it means re-entering the g5 capacity lottery. With it false, /sovran/model/vllm is
    the only signal from the GPU host during the ~1000s cold start.
  DESC
  default     = false
}

variable "s3_endpoint_policy" {
  type        = bool
  description = <<-DESC
    Attach a restrictive policy to the S3 gateway endpoint, limiting it to this account's
    project buckets plus the AWS-owned ECR layer bucket. Without it the endpoint permits
    every bucket in the partition, which makes S3 a viable exfiltration path for a
    compromised agent — the one egress the no-NAT tiers still have.

    Set false only to unblock yourself: if AWS renames the ECR layer bucket, image pulls
    start failing with CannotPullContainerError and this is the first thing to rule out.
  DESC
  default     = true
}

variable "model_port" {
  type        = number
  description = "HTTP port for the model service and internal LB target."
  default     = 8000
}

variable "model_ami_id" {
  type        = string
  description = "AMI ID from Packer (vLLM + baked Gemma). Required — Fargate model-stub path was removed."

  validation {
    condition     = var.model_ami_id != ""
    error_message = "model_ami_id is required (model plane is GPU AMI only)."
  }
}

variable "model_instance_type" {
  type        = string
  description = "GPU instance type for the model ASG. Prefer g5.xlarge (24GB A10G) for Gemma4 E2B; g4dn.xlarge is only 16GB T4."
  default     = "g5.xlarge"
}

variable "model_asg_desired" {
  type        = number
  description = "Desired capacity for model GPU ASG (capped at max_size=1)."
  default     = 0

  validation {
    condition     = var.model_asg_desired >= 0 && var.model_asg_desired <= 1
    error_message = "model_asg_desired must be 0 or 1 (ASG max_size is 1)."
  }
}

variable "model_health_check_type" {
  type        = string
  description = "ASG health check source. Use EC2 during first bring-up so a slow/failed vLLM load can be inspected over SSM; ELB for demos."
  default     = "ELB"

  validation {
    condition     = contains(["ELB", "EC2"], var.model_health_check_type)
    error_message = "model_health_check_type must be ELB or EC2."
  }
}

variable "model_health_check_grace_seconds" {
  type        = number
  description = "Grace period before health checks can replace the instance. Set from the measured cold-boot time (EBS hydration + weight load + compile)."
  default     = 2400
}

variable "model_log_retention_days" {
  type        = number
  description = "Retention for the model plane vLLM log group."
  default     = 14
}

variable "netcheck_image_tag" {
  type        = string
  description = "Image tag for the netcheck probe. Ignored when netcheck_image_digest is set."
  default     = "latest"
}

variable "netcheck_image_digest" {
  type        = string
  description = <<-DESC
    Optional sha256:... digest for the netcheck image, overriding netcheck_image_tag.
    Empty = pull by tag. See var.registry_mode for why digests are the recommended form.
  DESC
  default     = ""

  validation {
    condition     = var.netcheck_image_digest == "" || startswith(var.netcheck_image_digest, "sha256:")
    error_message = "netcheck_image_digest must be empty or a full sha256:... digest."
  }
}

variable "registry_mode" {
  type        = string
  description = <<-DESC
    Where container images are served from (PLAN.md Phase 8).

      "ecr" — Elastic Container Registry. Costs the ecr.api + ecr.dkr interface endpoints
              (~$32/month across 2 AZs) and forces the S3 gateway policy to allow the
              AWS-owned prod-<region>-starport-layer-bucket, because that is where ECR
              keeps layers and a Fargate pull fetches them straight through this endpoint.
      "s3"  — a read-only Docker registry served as static objects from a bucket in this
              account, reached over the free S3 gateway endpoint. Both ECR endpoints and
              every ECR permission on the execution role disappear (the pull is anonymous),
              and the gateway policy stops naming a bucket we cannot inspect.

    Proven on 2026-08-14 in eu-west-2: Fargate pulled netcheck from S3 by digest AND by
    tag, ran it, and the task stopped with EssentialContainerExited — not a pull error.
    The two documented risks did not materialise: containerd asks for /v2/ but accepts a
    plain {} with no Docker-Distribution-Api-Version header, and it never needs the
    Docker-Content-Digest header S3 cannot send.

    Default is "s3" as of 2026-08-14, when the condition set for flipping it was met: the
    full Phase 4 demo ran end to end on "s3" over PrivateLink against a live GPU, with the
    real agent and sync images, not just the 10 MB alpine probe. Set "ecr" to fall back —
    it is a one-variable revert, and the ECR path is still built and tested.

    The trade, stated plainly: the registry bucket allows anonymous s3:GetObject from this
    VPC endpoint, so any process in the VPC can read every image layer — including the
    credential-free agent container reading the sync container's source. Not a credential
    leak, but a posture regression that compounds the shared-task-role limitation, and the
    price of closing the gateway-policy hole.
  DESC
  default     = "s3"

  validation {
    condition     = contains(["ecr", "s3"], var.registry_mode)
    error_message = "registry_mode must be \"ecr\" or \"s3\"."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged onto all resources."
  default     = {}
}
