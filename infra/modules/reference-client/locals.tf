locals {
  name_prefix = "${var.project_slug}-${var.client_slug}"

  base_tags = merge(
    {
      Project   = var.project_slug
      Client    = var.client_slug
      ManagedBy = "terraform"
    },
    var.tags,
  )

  # A digest pins the image; a tag only names it. Under registry_mode = "s3" pinning also
  # removes the one thing S3 cannot do — it has no Docker-Content-Digest header to send, so
  # a client resolving a tag is trusting bytes it cannot verify, while a client pulling by
  # digest checks them against the digest it asked for. Tags still work (measured on
  # Fargate, 2026-08-14); digests are what a demo should reference.
  agent_image = var.agent_image_digest != "" ? "${var.agent_repository_url}@${var.agent_image_digest}" : "${var.agent_repository_url}:${var.agent_image_tag}"
  sync_image  = var.sync_image_digest != "" ? "${var.sync_repository_url}@${var.sync_image_digest}" : "${var.sync_repository_url}:${var.sync_image_tag}"

  cmk_enabled = var.bucket_encryption == "aws:kms"
}
