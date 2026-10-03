# Sovran Phase 5 — bake vLLM + google/gemma-4-E2B-it into an AMI.
#
# Base image: Amazon Deep Learning AMI (AL2023 + NVIDIA), never an older Sovran AMI.
# Packer is an operator step (not Terraform). Prefer the reference account default
# VPC (public subnet + IGW) so GPU quota and internet are available for bake/SSH debug.
#
# Required env:
#   export AWS_PROFILE=sovran-ref
#   export HF_TOKEN=hf_...
#
# Example (eu-west-2 / g6.xlarge):
#   packer init packer/
#   packer build \
#     -var "region=eu-west-2" \
#     -var "vpc_id=vpc-..." \
#     -var "subnet_id=subnet-..." \
#     -var "instance_type=g6.xlarge" \
#     packer/model-ami.pkr.hcl
#
# Defaults to the latest nightly vLLM (upstream's Gemma 4 recipe ships pre-release).
# Once a version is proven on a debug host, pin it: -var "vllm_version=0.28.0.devNNN".
#
# An AMI is region-scoped: a bake in eu-west-2 cannot be launched by an ASG in eu-west-1
# and vice versa. Each region needs its own build and its own model_ami_id in tfvars.
# Both are recorded in packer/README.md — do not paste one region's id into the other.
#
# Region/GPU choice, measured 2026-08-14:
#   eu-west-1  g5.xlarge  (A10G, sm_86, 24GB)  offered in 2 AZs
#   eu-west-2  g6.xlarge  (L4,   sm_89, 24GB)  offered in 3 AZs — g5 only in 2, g6 absent
#                                              from eu-west-1 entirely
# Three AZs of capacity is the reason to prefer eu-west-2: Phase 5 lost hours to
# InsufficientInstanceCapacity on g5 in eu-west-1. Same 24GB, so every memory number
# baked below (MAX_MODEL_LEN, GPU_MEM_UTIL) carries over unchanged. L4 has roughly half
# the memory bandwidth of A10G (~300 vs ~600 GB/s), so expect slower decode, not less
# context. Both are CUDA 12 / sm_8x, so the same wheels apply with no arch flags.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_id" {
  type        = string
  description = "Client VPC with internet (public subnet) for the temporary builder."
}

variable "subnet_id" {
  type        = string
  description = "Public subnet ID for the Packer builder instance."
}

variable "instance_type" {
  type        = string
  description = <<-DESC
    Builder instance. Must be the same GPU family the ASG will run: the bake's smoke test
    is the only evidence the AMI serves tokens, and it only proves it for the GPU it ran on.
    g6.xlarge (L4, eu-west-2) or g5.xlarge (A10G, eu-west-1) — both 24GB, both fit Gemma4
    E2B at the baked MAX_MODEL_LEN. m5.xlarge only with skip_gpu_smoke=true, which brands
    the AMI UNVALIDATED.
  DESC
  default     = "g5.xlarge"
}

variable "skip_gpu_smoke" {
  type        = bool
  description = "Skip starting vLLM during bake (required when builder has no GPU)."
  default     = false
}

variable "ami_users" {
  type        = list(string)
  description = "AWS account IDs allowed to launch this AMI (reference account)."
  default     = []
}

variable "project_slug" {
  type    = string
  default = "sovran"
}

variable "model_id" {
  type    = string
  default = "google/gemma-4-E2B-it"
}

variable "model_revision" {
  type        = string
  description = "HF revision/commit to pin. Empty = resolve main at build time and record it."
  # Pin from successful 2026-08-06 bake of google/gemma-4-E2B-it
  default = "3e22461f65e89153144f8adb70e3b8c2cc9845a7"
}

variable "vllm_version" {
  type        = string
  description = <<-DESC
    vLLM version to install. Empty = latest from the selected index.
    Pinned to 0.27.1: proven serving google/gemma-4-E2B-it on an A10G on 2026-08-12
    (completion + parsed tool call). Note the nightly index tops out at
    0.26.1rc1.dev688, i.e. older than the 0.27.1 release, so --pre resolves to the
    same wheel. 0.27.1 still requires the head_dim patch (03b) for Gemma 4.
  DESC
  default     = "0.27.1"
}

variable "vllm_pre_release" {
  type        = string
  description = <<-DESC
    true = install with --pre from vllm_index_url; false = released PyPI wheel (requires
    vllm_version). Defaults to false now that vllm_version is pinned to a proven release:
    the nightly index adds nothing today (its newest build is older than 0.27.1) and a
    released wheel is the reproducible choice. Flip to true with vllm_version="" to chase
    a nightly once one carries newer Gemma 4 support.
  DESC
  default     = "false"
}

variable "vllm_index_url" {
  type        = string
  description = "Extra index for pre-release wheels."
  default     = "https://wheels.vllm.ai/nightly"
}

variable "log_group" {
  type        = string
  description = "CloudWatch log group the baked cloudwatch-agent config writes to. Must match the group Terraform creates."
  default     = "/sovran/model/vllm"
}

variable "transformers_version" {
  type        = string
  description = "Optional transformers pin. Empty = let vLLM resolve (0.26 wants >=5.5.3)."
  default     = ""
}

variable "hf_token" {
  type        = string
  description = "Hugging Face token. Set via export HF_TOKEN=... or -var. Do not commit."
  # Packer resolves env() only in variable defaults.
  default   = env("HF_TOKEN")
  sensitive = true
}

variable "root_volume_gb" {
  type    = number
  default = 100
}

variable "use_spot" {
  type        = bool
  description = "Request a Spot builder. Requires Spot G quota > 0 (often still 0 when On-Demand G=4)."
  default     = false
}

variable "spot_price" {
  type        = string
  description = "When use_spot=true: Spot max price. Use \"auto\" for on-demand cap."
  default     = "auto"
}

variable "ssh_username" {
  type    = string
  default = "ec2-user"
}

locals {
  timestamp   = formatdate("YYYYMMDD-hhmmss", timestamp())
  token       = trimspace(var.hf_token)
  name_prefix = "${var.project_slug}-gemma4-e2b-vllm"

  vllm_slug = var.vllm_version != "" ? replace(var.vllm_version, ".", "-") : "nightly"

  # An AMI that skipped the GPU smoke has never served a token. Say so in the name, so
  # it cannot be pasted into terraform.tfvars by mistake. (04-smoke-local.sh now hard-fails
  # on a GPU-less builder, so this is only reachable via an explicit skip_gpu_smoke=true.)
  validation_slug = var.skip_gpu_smoke ? "UNVALIDATED" : "validated"
}

source "amazon-ebs" "model" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = var.ssh_username

  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  # Public IP required: bake needs HF/pip egress; -debug needs SSH from laptop.
  associate_public_ip_address = true
  ssh_interface               = "public_ip"

  # Temporary builder SG: SSH from anywhere (build only; deleted with instance).
  # For tighter debug, pass temporary_security_group_source_cidrs via HCL override.
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]

  # Spot: amazon plugin uses spot_price != "" to request Spot (no spot_instance bool).
  # Reference account often has On-Demand G quota but Spot G = 0 — keep use_spot=false then.
  spot_price          = var.use_spot ? var.spot_price : ""
  spot_instance_types = var.use_spot ? [var.instance_type] : []

  ami_name        = "${local.name_prefix}-${local.vllm_slug}-${local.validation_slug}-${local.timestamp}"
  ami_description = "Sovran model plane: vLLM ${local.vllm_slug} + ${var.model_id} (weights baked, no runtime HF egress) [${local.validation_slug}]"
  ami_users       = var.ami_users

  # Provisioned IOPS matter more than throughput here. vLLM loads safetensors via mmap,
  # i.e. cold 4KB random reads: a default gp3 (3000 IOPS) caps at ~12 MB/s no matter the
  # MB/s setting, which made a 9.19 GiB load take 1354 s and blow the smoke timeout on
  # the 2026-08-12 bake. The page cache cannot cover it either — 16 GiB RAM vs a 9.6 GiB
  # model means the prewarm's cached pages get evicted during engine startup.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    iops                  = 12000
    throughput            = 750
    delete_on_termination = true
  }

  # Deep Learning AMI (AL2023) with NVIDIA drivers — speeds vLLM install.
  source_ami_filter {
    filters = {
      name                = "Deep Learning Base OSS Nvidia Driver GPU AMI (Amazon Linux 2023)*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    owners      = ["amazon", "898082745236"] # amazon / DLAMI publisher
    most_recent = true
  }

  tags = {
    Name        = "${local.name_prefix}-${local.vllm_slug}-${local.validation_slug}-${local.timestamp}"
    Project     = var.project_slug
    Component   = "model"
    ModelId     = var.model_id
    VllmVersion = local.vllm_slug
    Validated   = var.skip_gpu_smoke ? "false" : "true"
    ManagedBy   = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.model"]

  provisioner "shell" {
    environment_vars = [
      "HF_TOKEN=${local.token}",
      "HUGGING_FACE_HUB_TOKEN=${local.token}",
      "MODEL_ID=${var.model_id}",
      "MODEL_REVISION=${var.model_revision}",
      "VLLM_VERSION=${var.vllm_version}",
      "VLLM_PRE_RELEASE=${var.vllm_pre_release}",
      "VLLM_INDEX_URL=${var.vllm_index_url}",
      "TRANSFORMERS_VERSION=${var.transformers_version}",
      "LOG_GROUP=${var.log_group}",
      "MODEL_DIR=/opt/sovran/models/gemma-4-E2B-it",
      "VLLM_PORT=8000",
      "SKIP_GPU_SMOKE=${var.skip_gpu_smoke}",
      # Empty = let vLLM choose. Measured on 0.27.1 / A10G (2026-08-12): vLLM selects
      # per layer group — FLASH_ATTN for the 28 sliding layers, FLASHINFER for the 7
      # full-attention layers (head_dim 512). VLLM_ATTENTION_BACKEND=TRITON_ATTN did
      # not restrict that choice at all, so forcing it was a no-op carried since the
      # T4 era ("FA2 caps at head_dim 256"). Set a value here only to override.
      "ATTENTION_BACKEND=",
      # Full native context. Measured on a 24GB A10G at util 0.85: 131072 uses exactly
      # the same GPU memory as 4096 (9.59 GiB weights + 8.9 GiB KV cache), because
      # vLLM pages KV per token actually used — max_model_len only has to fit one
      # sequence. KV holds 1,452,356 tokens = 11.08x concurrency at full length.
      # An 18k-token prompt was served successfully. The old 4096 came from an
      # 8192@0.90 OOM that was really a memory-fraction problem, not a context limit.
      "MAX_MODEL_LEN=131072",
      "GPU_MEM_UTIL=0.85",
      "DTYPE=auto",
      "LIMIT_MM_JSON={\"image\":0,\"audio\":0}",
    ]
    scripts = [
      "${path.root}/scripts/01-install-vllm.sh",
      "${path.root}/scripts/02-download-model.sh",
      "${path.root}/scripts/03-systemd-vllm.sh",
      "${path.root}/scripts/03b-patch-gemma4-head-dim.sh",
      "${path.root}/scripts/04-smoke-local.sh",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /tmp/* /home/ec2-user/.cache/huggingface/token || true",
      "sudo rm -f /root/.cache/huggingface/token || true",
      "history -c || true",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
