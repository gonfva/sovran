locals {
  name_prefix = var.project_slug

  base_tags = merge(
    {
      Project   = var.project_slug
      Client    = "platform"
      ManagedBy = "terraform"
    },
    var.tags,
  )

  # Fixed /24 tiers inside vpc_cidr (expects /16 by default).
  # endpoint: .0/.1  agent: .10/.11  model: .20/.21  (per AZ index)
  endpoint_subnet_cidrs = [
    for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)
  ]
  agent_subnet_cidrs = [
    for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)
  ]
  model_subnet_cidrs = [
    for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 20 + i)
  ]

  # Session Manager is the only shell into a no-NAT model subnet, but it costs three
  # endpoints and nothing uses it at runtime — it is a bring-up tool. Off by default;
  # see var.model_ssm_access for when to turn it on. ssm alone is not enough.
  ssm_services = var.model_ssm_access ? {
    ssm         = "ssm"
    ssmmessages = "ssmmessages"
    ec2messages = "ec2messages"
  } : {}

  registry_s3 = var.registry_mode == "s3"

  # Both ECR endpoints exist only to pull images. Under registry_mode = "s3" the images
  # come from a bucket over the free gateway endpoint, so these two go the way of kms and
  # sts — and netcheck_blocked_hosts below picks them up automatically, which is what keeps
  # a silent re-add from going unnoticed.
  ecr_services = local.registry_s3 ? {} : {
    ecr_api = "ecr.api"
    ecr_dkr = "ecr.dkr"
  }

  # Keys are logical, not service names, and are load-bearing: aws_vpc_endpoint.interface
  # is for_each'd over this map, so re-keying it (or converting to toset) destroys and
  # recreates every endpoint instead of just the ones that changed.
  #
  # Deliberately absent: kms and sts.
  #   sts — task creds come from the ECS credential endpoint (link-local 169.254.170.2),
  #         EC2 creds from IMDS. The sts:AssumeRole strings in iam.tf are trust policy
  #         documents, not API calls. Nothing here opens a socket to STS.
  #   kms — SSE-KMS on S3 is decrypted inside S3, service-side; the sync containers never
  #         instantiate a KMS client or send SSE-KMS headers. Adding any client-side KMS
  #         call (app-level kms:Decrypt, SSE-C, envelope crypto) needs this endpoint back.
  interface_services = merge({
    logs = "logs"
  }, local.ecr_services, local.ssm_services)

  # Registry host and per-repo prefixes. Both modes produce the same shape — a host plus a
  # repository path — so everything downstream (including reference-client) appends either
  # ":tag" or "@sha256:..." without caring which registry it is talking to.
  registry_host = local.registry_s3 ? "${aws_s3_bucket.registry[0].bucket}.s3.${var.region}.amazonaws.com" : ""

  repository_urls = local.registry_s3 ? {
    for k, v in local.ecr_repos : k => "${local.registry_host}/${v.name}"
    } : {
    for k, r in aws_ecr_repository.this : k => r.repository_url
  }

  # Netcheck asserts both directions: an endpoint we build must answer on 443, and one we
  # removed must not. Written out rather than derived from interface_services because the
  # service name and the DNS name disagree ("ecr.api" is served at api.ecr.<region>...),
  # and a clever transform would be harder to check than the four lines it replaces.
  #
  # ecr_dkr must carry the account id. That endpoint's private DNS is the wildcard
  # *.dkr.ecr.<region>.amazonaws.com, which matches <account>.dkr.ecr... but NOT the bare
  # dkr.ecr... — a wildcard needs a label to match. Probing the bare name fails DNS and
  # reports a working endpoint as missing (observed on the 2026-08-14 live run, while the
  # very task doing the probing had just pulled its own image through that endpoint).
  endpoint_hostnames = {
    ecr_api     = "api.ecr.${var.region}.amazonaws.com"
    ecr_dkr     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    logs        = "logs.${var.region}.amazonaws.com"
    ssm         = "ssm.${var.region}.amazonaws.com"
    ssmmessages = "ssmmessages.${var.region}.amazonaws.com"
    ec2messages = "ec2messages.${var.region}.amazonaws.com"
    kms         = "kms.${var.region}.amazonaws.com"
    sts         = "sts.${var.region}.amazonaws.com"
  }

  netcheck_expected_hosts = [
    for k, _ in local.interface_services : local.endpoint_hostnames[k]
  ]

  # Everything we know about that we deliberately did not build. kms/sts are permanent
  # (no in-VPC caller); the SSM trio moves between the two lists with model_ssm_access.
  netcheck_blocked_hosts = [
    for k, host in local.endpoint_hostnames : host
    if !contains(keys(local.interface_services), k)
  ]
}
