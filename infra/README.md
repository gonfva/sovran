# Sovran infrastructure

Terraform and operator docs for the **privacy-preserving agent + inference** PoC.  
Authoritative design: [`../PLAN.md`](../PLAN.md). This file is the **apply / demo / destroy** runbook.

## Prerequisites

| Tool | Version | Notes |
|------|---------|--------|
| AWS CLI | v2 preferred (v1 works for profile checks) | Named profiles for three accounts |
| Terraform | ≥ 1.5 | Not required for Phase 0 |
| Docker | any recent | Image builds (Phase 1 model-stub + later agents) |
| Packer | any recent | GPU AMI only (Phase 5) |

### AWS accounts

Three **already-created** accounts (Terraform does **not** vend accounts):

| Role | Purpose |
|------|---------|
| **reference** | Shared VPC, agents, model plane, per-client buckets/keys, PrivateLink endpoint services |
| **client-a** | Client VPC, SSM EC2, interface endpoint to its agent only |
| **client-b** | Same pattern as client-a; isolated from client-a |

Region is chosen at apply time (prefer a region with GPU quota if Phase 5 is in scope). Example in config: `eu-west-1`.

## Configuration

1. Copy the example config:

   ```bash
   cp config.example.hcl config.hcl
   ```

2. Edit `config.hcl`: set `region`, real `account_id` values, and `profiles` names that match your local AWS CLI setup.

3. **Never commit** `config.hcl`, credentials, or Terraform state. See repo `.gitignore`.

### Config shape

See [`config.example.hcl`](./config.example.hcl). Required keys:

- `region`, `project_slug`
- `profiles.reference`, `profiles.client_a`, `profiles.client_b`
- `reference_account_id`
- `clients.a` / `clients.b` with `slug` and `account_id`

Default profile names (override if needed):

| Config key | Default profile name |
|------------|----------------------|
| `profiles.reference` | `sovran-ref` |
| `profiles.client_a` | `sovran-client-a` |
| `profiles.client_b` | `sovran-client-b` |

## AWS profiles (Phase 0 exit)

Each profile must authenticate to the correct account.

### Create profiles (example)

In `~/.aws/credentials` (access keys) or `~/.aws/config` (SSO / assume-role):

```ini
# ~/.aws/credentials  (example — use your real keys; do not commit)
[sovran-ref]
aws_access_key_id = AKIA...
aws_secret_access_key = ...

[sovran-client-a]
aws_access_key_id = AKIA...
aws_secret_access_key = ...

[sovran-client-b]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

Optional region defaults in `~/.aws/config`:

```ini
[profile sovran-ref]
region = eu-west-1

[profile sovran-client-a]
region = eu-west-1

[profile sovran-client-b]
region = eu-west-1
```

SSO example (adjust start URL / account / role):

```ini
[profile sovran-ref]
sso_start_url = https://example.awsapps.com/start
sso_region = eu-west-1
sso_account_id = 333333333333
sso_role_name = AdministratorAccess
region = eu-west-1
```

### Verify all three profiles

Replace names if you overrode `profiles` in `config.hcl`:

```bash
aws sts get-caller-identity --profile sovran-ref
aws sts get-caller-identity --profile sovran-client-a
aws sts get-caller-identity --profile sovran-client-b
```

Expected: each command returns a distinct `Account` matching `reference_account_id` / `clients.*.account_id` in `config.hcl`.

**Phase 0 exit criterion:** operator can authenticate to all three accounts this way.

Permissions each profile needs (later phases): create/manage VPC, ECS, EC2, IAM, S3, KMS, ELB, VPC endpoints / endpoint services in **that** account. Least-privilege custom roles are fine if they cover those APIs.

## Apply order (by phase)

Implement and apply **in order**. Do not skip isolation proofs (Phase 3).

| Phase | What | Accounts | Status |
|-------|------|----------|--------|
| **0** | Docs + `config.example.hcl` + profile auth | — (local only) | Done |
| **1** | Reference VPC, endpoints, ECS cluster, stub model + internal LB | reference | Done |
| **2** | Client-a vertical: buckets, agent task, NLB/EPS, client VPC + PrivateLink | reference + client-a | Done |
| **3** | Client-b + isolation tests (`for_each` clients map) | reference + client-b | Done |
| **4** | Real agent + sync images (tools + jail) | reference | Done |
| **5** | vLLM + Gemma-4-E2B-it AMI / GPU ASG (max 1) | reference + Packer | **Done — proven on a live A10G (eu-west-1, 2026-08-13) and a live L4 (eu-west-2, 2026-08-14)** |
| **6** | Endpoint diet, hardening, cost table, destroy runbook polish | all | **Done — verified on a live apply, 2026-08-14** |
| **7** | Marketing site | not in this repository — [sovran.uk](https://sovran.uk) | Done |
| **8** | ECR removed; images served from a VPCE-gated S3 registry | reference | **Done — spike passed and applied live, 2026-08-14** |

### Terraform layout

```
infra/
├── README.md
├── config.example.hcl
├── config.hcl                 # local only (gitignored)
├── modules/
│   ├── reference-core/        # VPC, endpoints, ECS cluster, model stub, ECR
│   ├── reference-client/      # per-client: CMK, buckets, agent task, NLB, EPS
│   └── client/                # client VPC, SSM EC2, interface VPCE
└── envs/
    ├── reference/             # profile: sovran-ref (core + all clients via for_each)
    ├── client-a/              # profile: sovran-client-a
    └── client-b/              # profile: sovran-client-b
```

Provider style: **named profiles** via `profile =` on separate env roots. No account creation in code.

**Apply order:** `envs/reference` (core + `var.clients` map) → push images → each `envs/client-*` (needs that client’s `endpoint_service_name` from reference outputs).

**Add a third client (no Terraform fork):**

1. Add an entry to `clients` in `infra/envs/reference/terraform.tfvars` and `terraform apply`.  
2. Copy `infra/envs/client-a` → `infra/envs/client-c` (or reuse the same module root with new tfvars), set profile/account/slug/CIDR/`endpoint_service_name`, apply.

## Running in another region

`region` is a variable everywhere and nothing in the modules hardcodes one, so a fresh apply
in a new region works as-is. Four things do **not** travel with it:

| Thing | Why it is regional | What to do |
|---|---|---|
| The model AMI | AMIs are region-scoped; an eu-west-1 id cannot launch in eu-west-2 | Re-bake with `packer build -var region=<region>` and put the new id in that region's tfvars |
| The GPU instance type | `g6.xlarge` does not exist in eu-west-1; in eu-west-2 `g5` covers only 2 AZs while `g6` covers all 3 | `g5.xlarge` (A10G) in eu-west-1, `g6.xlarge` (L4) in eu-west-2. Both 24GB, so every baked memory setting carries over |
| Cross-account PrivateLink | An endpoint service and its consumer endpoint must be in the **same** region | Move `envs/client-a` / `envs/client-b` to the same region as `envs/reference`, or the demo cannot connect |
| The G-instance quota | Service quotas are per-region | Measured 2026-08-14: 4 vCPU in both eu-west-1 and eu-west-2 — exactly **one** `g6.xlarge`. The Packer builder consumes the whole quota, so bake and run cannot overlap. Let the build finish before `model_asg_desired = 1` |

Terraform state is local and per-env, so switching an env's region is a full create in the
new region — do it from a torn-down stack, not a live one.

## Phase 1 — apply (reference account)

Creates: VPC (endpoint / agent / model tiers × `az_count` AZs, **no NAT/IGW**), interface endpoints (Logs, plus ECR API/DKR under `registry_mode = "ecr"`, plus the SSM trio only when `model_ssm_access = true`) spread over `endpoint_az_count` AZs, policied S3 gateway, ECS cluster, internal model ALB, GPU model ASG, ECR repos *or* the S3 registry bucket, netcheck task definition. `kms` and `sts` are deliberately absent — see "Why `kms` and `sts` are gone".

### 1. Configure tfvars

```bash
cd infra/envs/reference
cp terraform.tfvars.example terraform.tfvars
# set aws_profile, region, reference_account_id to match infra/config.hcl
```

### 2. Apply

```bash
cd infra/envs/reference
terraform init
terraform apply
```

### 3. Build and push images (from a machine with internet)

Which half of this section applies depends on `registry_mode`. Both produce the same three
images; they differ only in where those images are served from. See "Phase 8 — images from
S3 instead of ECR" for the choice.

#### `registry_mode = "s3"` (default)

No `docker login`, no ECR, no credentials in the pull path at all. `scripts/push-images-s3.py`
renders each image as a static `/v2/` registry tree and uploads it with the Content-Types a
registry would send. It needs only `docker` and the AWS CLI.

```bash
export AWS_PROFILE=sovran-ref
cd infra/envs/reference
BUCKET=$(terraform output -raw registry_bucket)

docker build --platform linux/amd64 -t sovran/netcheck:latest ../../../images/netcheck
docker build --platform linux/amd64 -t sovran/agent:latest    ../../../images/agent
docker build --platform linux/amd64 -t sovran/sync:latest     ../../../images/sync

../../../scripts/push-images-s3.py --bucket "$BUCKET" --region eu-west-2 \
  sovran/netcheck:latest sovran/agent:latest sovran/sync:latest
```

It prints one digest-pinned reference per image. Put the digests in `terraform.tfvars` and
apply again:

```hcl
registry_mode         = "s3"
netcheck_image_digest = "sha256:..."
agent_image_digest    = "sha256:..."
sync_image_digest     = "sha256:..."
```

**The first apply of a fresh S3 registry is necessarily two applies.** The bucket has to exist
before anything can be pushed to it, and a digest only exists after the push — so apply once
with the digests empty (references fall back to `:latest`, which works), push, then apply
again with the digests filled in. Tag references are a bootstrap step, not the end state:
S3 cannot send the `Docker-Content-Digest` header, so a client resolving a tag is trusting
bytes it has no way to verify, while a digest pull checks them against what it asked for.

`--render-only DIR` writes the tree to disk and skips the upload, which is the fastest way to
see what is actually being served.

#### `registry_mode = "ecr"` (fallback)

```bash
export AWS_PROFILE=sovran-ref
export AWS_DEFAULT_REGION=eu-west-1   # or your region
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

aws ecr get-login-password --region "$AWS_DEFAULT_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# Three repos exist: netcheck, agent, sync. The model plane is the GPU AMI —
# images/model-stub/ is dead code from before Phase 5 and has no ECR repo.
docker build --platform linux/amd64 -t "${REGISTRY}/sovran/netcheck:latest" ../../../images/netcheck
docker build --platform linux/amd64 -t "${REGISTRY}/sovran/agent:latest" ../../../images/agent
docker build --platform linux/amd64 -t "${REGISTRY}/sovran/sync:latest" ../../../images/sync
docker push "${REGISTRY}/sovran/netcheck:latest"
docker push "${REGISTRY}/sovran/agent:latest"
docker push "${REGISTRY}/sovran/sync:latest"

aws ecs update-service --cluster sovran-ref --service sovran-alpha-agent \
  --force-new-deployment --region "$AWS_DEFAULT_REGION"
aws ecs wait services-stable --cluster sovran-ref \
  --services sovran-alpha-agent \
  --region "$AWS_DEFAULT_REGION"
```

> **Phase 6 changed `images/netcheck/`.** The endpoint assertions live in the image, not in
> Terraform, so an old `netcheck:latest` will silently skip sections 3 and 4 (it ignores the new
> `EXPECTED_HOSTS`/`BLOCKED_HOSTS` env vars). Re-push it before trusting the exit criteria.

### 4. Exit criteria (netcheck in agent subnet)

From `infra/envs/reference` after apply:

```bash
export AWS_PROFILE=sovran-ref
export AWS_DEFAULT_REGION=eu-west-1

CLUSTER=$(terraform output -raw ecs_cluster_name)
TASK_DEF=$(terraform output -raw netcheck_task_definition_arn)
SUBNETS=$(terraform output -json agent_subnet_ids | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')
SG=$(terraform output -raw agent_security_group_id)

TASK_ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text
# expect 0

# logs: /sovran/netcheck  — four sections, all PASS
```

**Exit:** agent-subnet task can `curl` model `/health`; same task cannot reach `https://example.com`; every endpoint in `EXPECTED_HOSTS` answers on 443; nothing in `BLOCKED_HOSTS` does.

> **netcheck cannot exit 0 with `model_asg_desired = 0`.** The model plane is GPU-only since
> the Fargate stub was removed, so with no instance the internal ALB has no healthy target and
> section 1 fails with `curl: (22) ... error: 503` — the endpoint sections still run and still
> mean what they say. Read the log rather than the exit code when verifying the endpoint diet
> without paying for a GPU; expect `exit 1` with sections 2–4 all PASS. Only judge by exit code
> once a GPU is up.

Sections 3 and 4 were added in Phase 6 and are derived from `local.interface_services`, so they cannot drift from the endpoints Terraform actually builds. They catch both directions of mistake: an endpoint quietly re-added (paying for something with no caller) and one wrongly removed (a demo that fails later, somewhere less obvious). Reachability means *something answered on 443* — an interface endpoint returns an HTTP error to an unsigned request, and that error is the proof; only a connect or DNS failure counts as absent.

With the defaults, `BLOCKED_HOSTS` covers `kms`, `sts`, and the SSM trio. Flip `model_ssm_access = true` and the trio moves to `EXPECTED_HOSTS` automatically.

Useful outputs: `model_base_url`, `agent_subnet_ids`, `agent_security_group_id`, `ecs_cluster_name`, `client_a_endpoint_service_name`, `client_a_data_bucket`.

## Phase 2 — client-a vertical slice

**Reference side** (included in `envs/reference` apply): CMK + code/data buckets, task role, 3-container agent task (sync-down / agent / sync-up), ECS service in agent subnets, NLB in endpoint subnets, VPC endpoint service allowing client-a account.

**Client-a side** (`envs/client-a`): public subnet + IGW, SSM-only EC2 (no SSH/inbound), interface VPC endpoint to the endpoint service.

### Apply client-a

```bash
# after reference apply:
EPS=$(cd infra/envs/reference && terraform output -raw client_a_endpoint_service_name)

cd infra/envs/client-a
cp terraform.tfvars.example terraform.tfvars
# set aws_profile, client_account_id, endpoint_service_name=$EPS
terraform init
terraform apply
```

### Exit criteria demo (SSM → PrivateLink → agent → model → S3)

```bash
export AWS_DEFAULT_REGION=eu-west-1
INSTANCE_ID=$(cd infra/envs/client-a && terraform output -raw ec2_instance_id)
AGENT_URL=$(cd infra/envs/client-a && terraform output -raw agent_url)
DATA_BUCKET=$(cd infra/envs/reference && terraform output -raw client_a_data_bucket)

# Wait until SSM shows Online, then:
aws ssm send-command --profile sovran-client-a \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[
    \"curl -fsS $AGENT_URL/health\",
    \"curl -fsS -X POST $AGENT_URL/v1/demo -H 'Content-Type: application/json' -d '{\\\"message\\\":\\\"hello\\\"}'\"
  ]"

# After ~sync interval (default 15–30s), session objects appear under:
aws s3 ls "s3://${DATA_BUCKET}/sessions/" --profile sovran-ref --recursive
```

**Exit:** PrivateLink HTTP from client EC2 succeeds; agent reply is model-stub echo; `sessions/<id>/` objects land in the client-a data bucket.

Agent API (stub): `GET /health`, `POST /v1/sessions`, `POST /v1/sessions/{id}/chat`, `POST /v1/demo`, `GET /v1/sessions/{id}/files`.

## Phase 3 — client-b + isolation

Reference already uses `module.clients` with `for_each = var.clients`. Adding **beta** is a second map entry (same module as alpha).

### Apply client-b

```bash
EPS=$(cd infra/envs/reference && terraform output -raw client_b_endpoint_service_name)
# or: terraform output -json clients | jq -r '.b.endpoint_service_name'

cd infra/envs/client-b
cp terraform.tfvars.example terraform.tfvars
# set endpoint_service_name, client_account_id, client_slug=beta, vpc_cidr=10.20.0.0/16
terraform init && terraform apply
```

Redeploy agent service after images exist: `aws ecs update-service --cluster sovran-ref --service sovran-beta-agent --force-new-deployment`.

### Isolation tests

| # | Test | How | Expected |
|---|------|-----|----------|
| 1 | Client-a → client-b agent | From client-a EC2 (SSM): `curl` client-b `agent_url` | Fail / not reachable |
| 1b | Client-a create VPCE to client-b EPS | `aws ec2 create-vpc-endpoint --service-name <client-b EPS>` in client-a | Error (`InvalidServiceName` / not authorized) |
| 2 | Task role A → bucket B | `aws iam simulate-principal-policy --policy-source-arn <role A> --action-names s3:GetObject --resource-arns arn:aws:s3:::<bucket-b>/documents/hello.txt` | not `allowed` |
| 3 | Task role B → bucket A | same with roles/buckets swapped | not `allowed` |
| 4 | Agent internet egress | Phase 1 netcheck task in agent subnets | exit 0 (model ok, `example.com` blocked) |

Example commands (fill ARNs/names from `terraform output`):

```bash
export AWS_DEFAULT_REGION=eu-west-1
# Cross-bucket (reference profile)
aws iam simulate-principal-policy --profile sovran-ref \
  --policy-source-arn "$(cd infra/envs/reference && terraform output -raw client_a_task_role_arn)" \
  --action-names s3:GetObject \
  --resource-arns "arn:aws:s3:::$(cd infra/envs/reference && terraform output -raw client_b_data_bucket)/documents/hello.txt"
# expect EvalDecision != allowed
```

**Exit:** Two clients isolated; third client is a new `clients` map entry + apply (plus a client-env apply in that account).

## Phase 4 — agent tools + jail

Agent image (`images/agent`, v0.4) includes:

| Piece | Role |
|-------|------|
| Path jail | Reads under `documents/`, `sessions/`, `code/`, `out/`; writes under `documents/`, `sessions/`, `out/` only (`code/` read-only) |
| Tools | `read_file`, `write_file`, `list_dir` (OpenAI function-calling schema) |
| Model client | OpenAI-compatible `/v1/chat/completions` at `MODEL_BASE_URL` (internal model LB) |
| Loop | Multi-round tool execution; local intent fallback if model returns no `tool_calls` |
| Logging | CloudWatch: metadata only (`client`, `session_id`, `latency_ms`, tool counts—**not** prompt bodies) |
| Transcript | `/workspace/sessions/<id>/transcript.jsonl` (tenant data → sync-up → S3) |

Sync image: prefix sync-down; periodic + SIGTERM sync-up of `sessions/` and `out/` (skips `.ready`, junk).

### Rebuild and redeploy images

```bash
export AWS_PROFILE=sovran-ref AWS_DEFAULT_REGION=eu-west-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

for img in agent sync model-stub; do
  docker build --platform linux/amd64 -t "${REGISTRY}/sovran/${img}:latest" ../../images/$img
  docker push "${REGISTRY}/sovran/${img}:latest"
done

for svc in sovran-model-stub sovran-alpha-agent sovran-beta-agent; do
  aws ecs update-service --cluster sovran-ref --service $svc --force-new-deployment
done
```

### Exit demo (PrivateLink + tools + S3)

```bash
AGENT_URL=$(cd infra/envs/client-a && terraform output -raw agent_url)
INSTANCE_ID=$(cd infra/envs/client-a && terraform output -raw ec2_instance_id)
DATA_BUCKET=$(cd infra/envs/reference && terraform output -raw client_a_data_bucket)

# Via SSM on client-a EC2:
curl -fsS "$AGENT_URL/health"   # version 0.4, tools listed
curl -fsS -X POST "$AGENT_URL/v1/demo" -H 'Content-Type: application/json' -d '{}'
# → list_dir + read_file(documents/hello.txt) + write_file(sessions/.../agent_note.txt)

# After sync interval:
aws s3 ls "s3://${DATA_BUCKET}/sessions/<session_id>/" --recursive
# expect transcript.jsonl, agent_note.txt, meta.json
```

Manual turn API:

```bash
curl -X POST "$AGENT_URL/v1/sessions" -d '{}'
curl -X POST "$AGENT_URL/v1/sessions/<id>/chat" \
  -H 'Content-Type: application/json' \
  -d '{"message":"read documents/hello.txt"}'
curl "$AGENT_URL/v1/sessions/<id>/files"
```

## Phase 5 — real model AMI (vLLM + Gemma 4 E2B-it)

Packer is **not** run by Terraform. Bake in the **reference** account (that is where the GPU
quota lives), from the **default VPC** (public subnet + IGW). HF credentials stay in the
environment:

```bash
export HF_TOKEN=hf_...   # required for bake only
export AWS_PROFILE=sovran-ref
export AWS_DEFAULT_REGION=eu-west-1
```

Full build commands and the debug-host workflow are in [`packer/README.md`](../packer/README.md).

**GPU facts for this region (verified 2026-08-12):**

| Fact | Value |
|------|-------|
| Quota *Running On-Demand G and VT instances* (reference) | **4 vCPU** = exactly one `g5.xlarge` |
| Target instance | **`g5.xlarge`** — A10G 24 GB, meets vLLM's documented 24 GB+ minimum for E2B |
| `g6.xlarge` in eu-west-1 | **Does not exist.** eu-west-1 offers `g4dn.*` and `g5.*` only. G quota is per-region, so chasing L4 means a new region *and* a new quota case |
| `g4dn.xlarge` | 16 GB T4, compute 7.5 — undersized for E2B. Do not use |

Because the quota is one instance, a leftover Packer/debug host makes the ASG fail with
`VcpuLimitExceeded`. Terminate debug hosts before applying.

**AZ capacity is the other placement failure, and it looks identical to a broken AMI.**
On 2026-08-13 `g5.xlarge` had **zero capacity in both `eu-west-1a` and `eu-west-1b`** —
`run-instances` failed in each, and AWS named `eu-west-1c` in both error messages. The debug
host on 2026-08-12 had already landed in `1c` only on its third attempt, so this is persistent,
not a one-off.

With `az_count = 2` the model subnets never reach `1c`, so neither a manual launch nor the ASG
can place there. Retrying is not the fix: an **ALB does not route to targets in an AZ where it
has no subnet**, so the instance must sit in an AZ the model ALB also occupies. The fix is
`az_count = 3` in `terraform.tfvars`, which is additive — subnet CIDRs are
`cidrsubnet(vpc_cidr, 8, base + i)`, so index 2 only appends `10.0.2.0/24` / `10.0.12.0/24` /
`10.0.22.0/24` and no existing subnet moves. Measured plan: **6 add, 14 change, 0 destroy**,
costing roughly **$0.09/hr** more (8 interface endpoints × one extra AZ ENI).

An ASG that cannot place capacity reports nothing on the target group — which is very likely
part of the historical "the ASG never came up" symptom, independent of the AMI being unvalidated.
Check `aws autoscaling describe-scaling-activities` before suspecting the model.

**How bad it gets:** on 2026-08-13 the ASG failed **21 consecutive launch attempts over 72
minutes**, all three AZs, while a manual `run-instances` earlier the same day had succeeded on
its third try within four minutes. Capacity comes and goes in windows; there is no lever that
makes it appear. `terraform apply` will *error* on the ASG capacity wait when this happens —
that failure is cosmetic, the ASG keeps `desired=1` and retries by itself, so do not re-apply
in a loop. Widening instance types is not an option either: the 4 vCPU quota excludes
`g5.2xlarge`, and `g4dn.xlarge` is a 16 GB T4 the AMI's A10G compile caches do not fit.

### Bring-up order (do not skip to the ASG)

The ASG is the *last* step, not the debugging tool — its only signal is a binary ALB health
check 40 minutes after boot.

1. **Debug host** (`packer/launch-debug-host.sh`) — prove vLLM serves and tool-calls at all.
2. **Same host, rebooted with all SG egress removed** — proves unattended boot with no internet,
   which is what the model subnet actually is.
3. **Bake** — `04-smoke-local.sh` now *fails* the build on a GPU-less builder instead of passing
   silently, and the AMI name carries `-validated-` or `-UNVALIDATED-`.
4. **Manual launch into a model subnet** with `model_asg_desired = 0` — read the journal over SSM
   before letting an ASG replace anything.
5. **ASG** — `model_asg_desired = 1`.

> **Steps 1–4 all need `model_ssm_access = true`.** It defaults to `false` (the SSM trio is three
> endpoints, ~$48/month, and nothing uses it at runtime — it is a bring-up tool, not a dependency).
>
> Set it in the **same apply** as `model_asg_desired = 1` whenever the AMI is new or unvalidated.
> Enabling it afterwards on a live GPU is best-effort — the endpoints take ~2 min to provision and
> the SSM agent's registration backoff can be minutes — and terminating the instance to fix it means
> re-entering the g5 capacity lottery documented below. For a demo on a known-good AMI, leave it
> `false`: `/sovran/model/vllm` still receives the full boot journal over the Logs endpoint.

### Wiring the AMI in

```hcl
# infra/envs/reference/terraform.tfvars
model_ami_id        = "ami-xxxxxxxx"   # must be a *-validated-* AMI from packer
model_instance_type = "g5.xlarge"
model_asg_desired   = 1                # hard-capped at max_size=1

# During first bring-up only: keep a failed instance alive for inspection.
model_health_check_type = "EC2"
```

| Setting | Meaning |
|---------|---------|
| `model_ami_id` set, `model_asg_desired=0` | Launch template + TG + empty ASG exist; nothing running, ALB has no healthy target |
| `model_asg_desired=1` | ASG launches 1× GPU and registers it in the instance target group |
| `model_health_check_type=EC2` | ASG ignores ALB health; a broken vLLM survives for `journalctl` |
| `model_health_check_grace_seconds` | Default 2400 (40 min). Set from the cold-boot time measured in step 4 |

### Reading a failing model instance

The model subnet has no NAT. It always has the Logs interface endpoint; it has the SSM trio and the
instance-role `AmazonSSMManagedInstanceCore` attachment **only when `model_ssm_access = true`** (both
are gated on that one variable so they cannot drift apart). `CloudWatchAgentServerPolicy` is always
attached, so the journal path below works either way:

```bash
aws ssm start-session --target <instance-id>     # then: journalctl -u sovran-vllm -f
aws logs tail "$(terraform output -raw model_log_group)" --follow
```

The AMI ships the exact serve command as `/opt/sovran/serve.sh` — the systemd unit runs that
file, so an operator debugging by hand runs precisely what the unit runs. `/opt/sovran/build-info.txt`
records the resolved vLLM/torch/transformers versions, `validated=`, and the smoke timings.

Note `aws logs tail` is missing from some AWS CLI v2 builds, and `filter-log-events` returned
0 events here even for terms that were present. If either misbehaves, pull the stream and grep
locally — that is what actually worked on 2026-08-13:

```bash
aws logs get-log-events --log-group-name /sovran/model/vllm \
  --log-stream-name <instance-id> --start-from-head --limit 10000 --output json \
  | python3 -c 'import json,sys; [print(e["message"]) for e in json.load(sys.stdin)["events"]]'
```

**Logging invariant:** vLLM logs request prompts at INFO, and this journal ships to CloudWatch.
The bake refuses to produce an AMI unless the wheel supports request-log suppression
(`--max-log-len 0` / `--disable-log-requests`), so prompt bodies stay out of platform logs.
**Verified live on 2026-08-13**: a canary token sent inside a prompt appeared 0 times in
`/sovran/model/vllm`, while a control term present in the journal matched — so the search was
real, not a false negative. CloudWatch carried only `POST /v1/chat/completions` access lines.

### Measured cold start (Gate D, 2026-08-13)

`ami-0e47495c44fb7796f` launched from the ASG launch template into `10.0.22.0/24` (eu-west-1c):

| Milestone | Elapsed from `run-instances` |
|---|---|
| SSM registered | 60 s |
| Prewarm complete — 9802 MiB at **14 MiB/s** | 673 s |
| vLLM started | 716 s |
| **`/health` 200** | **1002 s** |
| ALB target `healthy` after `register-targets` | +30 s |

**Two thirds of cold start is EBS snapshot hydration, and gp3 settings will not fix it.**
14 MiB/s is nowhere near the volume's provisioned 6000 IOPS / 500 MB/s because AMI snapshot
blocks fault in from S3 on first touch. Raising `iops`/`throughput` in the launch template buys
nothing — this is the same trap as the bake, where 4× IOPS bought 5%. The real levers are EBS
**volume initialization rate** or **Fast Snapshot Restore** (FSR is billed per AZ-hour). Left
unoptimised for the PoC; 2400 s of grace covers 1002 s comfortably.

**Runtime:** no NAT, no HF egress (`HF_HUB_OFFLINE=1`); weights baked under
`/opt/sovran/models/gemma-4-E2B-it`.

### `MODEL_NAME` must match what vLLM serves

vLLM advertises the model under the `--model` **path** baked into the AMI, so the agent must
send exactly `/opt/sovran/models/gemma-4-E2B-it`. The agent image still defaults to
`sovran-stub` from the removed Fargate stub; when the task definition did not set `MODEL_NAME`,
every completion failed `404 The model 'sovran-stub' does not exist` while `/health`,
PrivateLink, ECS steady state and the S3 sync **all still looked green** — the demo returned
HTTP 502 with a transcript in S3 containing only the error. Now wired through `var.model_name`.
Verify against the live server rather than trusting the default:

```bash
curl -s http://<model_lb_dns>:8000/v1/models | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])'
```

### Phase 5 exit criteria — measured 2026-08-13

| Check | Result |
|---|---|
| ASG placement → ALB `healthy` | 885 s, unattended |
| netcheck (agent subnets) | exit 0 — model reachable, internet blocked |
| client EC2 → PrivateLink → agent → model → completion | HTTP 200, **2.8 s**, 3 turns, 4 tool calls |
| Transcript in client data bucket | `transcript.jsonl`, `meta.json`, `agent_note.txt` |
| Agent platform logs | 160 events, 0 prompt bodies |

**Cost:** `g5.xlarge` ≈ $1.2/hr dominates; control plane ≈ $0.40/hr. Cold start is ~15 min from
ASG placement, so treat this as demo-on-demand and destroy after (`scripts/teardown-all.sh`).

**A tainted ASG will destroy a working GPU.** When `terraform apply` errors on the ASG capacity
wait, the ASG is left tainted; the next plan then shows `must be replaced`, which terminates a
healthy instance and re-enters the capacity lottery. Untaint before applying anything else:

```bash
terraform untaint 'module.core.aws_autoscaling_group.model_gpu[0]'
```

**Cost:** `g5.xlarge` (~$1.2/hr in eu-west-1) dominates. Prefer `model_asg_desired=0` or a full
destroy when not demoing.

> Historical note: `ami-076b31d6a273f6b7a` (vLLM 0.19) and `ami-03ce9a122f75e2cc0` (vLLM 0.26,
> 18-minute bake) both predate the validated-AMI rule and **never passed a GPU smoke**. Do not
> wire either into tfvars.

## Destroy / cost awareness

Idle cost is real: **interface VPC endpoints**, **internal ALB**, **per-client NLB + EPS**, Fargate agent tasks, client EC2s, three-account sprawl.

### Interface endpoints — the largest idle line (Phase 6)

Interface endpoints are billed **per ENI per hour**: $0.011/hr in eu-west-1, i.e. **$8.03 per AZ per month, per endpoint**. The bill is endpoints × AZs, and both halves are now tunable.

| State | Endpoints × AZs | $/month |
|-------|-----------------|---------|
| Phases 0–5 as built (`ecr.api ecr.dkr logs kms sts ssm ssmmessages ec2messages` × 3 AZ) | 8 × 3 | **193** |
| Phase 6 default (`ecr.api ecr.dkr logs` × 2 AZ) | 3 × 2 | **48** |
| Phase 6 with `model_ssm_access = true` (GPU bring-up) | 6 × 2 | 96 |
| Phase 8 `registry_mode = "s3"` (`logs` × 2 AZ) — **measured live 2026-08-14** | 1 × 2 | **16** |

Three knobs, all in `infra/envs/reference/terraform.tfvars`:

| Variable | Default | Effect |
|----------|---------|--------|
| `endpoint_az_count` | `2` | How many AZs get endpoint ENIs. Independent of `az_count` — private DNS resolves cross-AZ, so the model tier can sit in a third AZ without a third set of ENIs. Floor of 2 by design: one ENI makes a single AZ a hard dependency for image pulls and log shipping. |
| `model_ssm_access` | `false` | Adds the `ssm`/`ssmmessages`/`ec2messages` trio **and** the instance-role attachment. See the Phase 5 bring-up rule below. |
| `registry_mode` | `"s3"` | Serves images from a VPCE-gated bucket over the free gateway endpoint, so neither ECR endpoint is created. `"ecr"` restores them. See "Phase 8 — images from S3 instead of ECR". |

**Why `kms` and `sts` are gone and should stay gone.** Neither had an in-VPC caller. SSE-KMS on S3 is decrypted *inside S3*, service-side — the sync containers never instantiate a KMS client or send SSE-KMS headers, so no socket to KMS is ever opened from the VPC. Task credentials come from the ECS credential endpoint (link-local `169.254.170.2`) and EC2 credentials from IMDS; the `sts:AssumeRole` strings in `iam.tf` are trust-policy documents, not API calls. `netcheck` now asserts both are unreachable, so a re-add fails the harness rather than quietly appearing on the bill.

### Considered and rejected: CloudWatch Logs → S3

Replacing the `logs` endpoint with FireLens/fluent-bit for ECS and a log shipper on the GPU host. Recorded here because the idea keeps coming back.

- It buys **$8–16/month** after the cuts above, not the $24 it looks like up front.
- It adds `s3:PutObject` to the **single shared ECS task role**, giving a compromised agent — the exact prompt-injection threat this design exists to counter — a new write channel. That is `WEAKNESSES.md` #1, made worse.
- It adds `s3:PutObject` to the **model instance role, which today has zero S3 permissions** while seeing every prompt in plaintext. That is precisely the exfiltration channel no-NAT exists to remove.
- With `model_ssm_access = false`, `/sovran/model/vllm` is the *only* window into a GPU that will not go healthy. Replacing it with a timer-flushed S3 sink — written by an agent that may itself be what is broken — leaves you blind during the exact ~1000s window the Gate D measurements say you need to watch. S3 log objects are also not greppable without downloading them.
- It does not even remove the endpoint unless `netcheck` converts too, which means instrumenting the proof harness with the thing under test.

If log cost ever matters, the levers are `retention_in_days` (already 7/14) and `endpoint_az_count`.

### S3 gateway endpoint policy

`s3_endpoint_policy = true` (default) restricts the gateway to `arn:aws:s3:::sovran-<account>-*`. S3 is the one egress the no-NAT tiers still have, so an unpolicied gateway means a compromised agent can read or write *any* bucket in the partition that allows it.

Under `registry_mode = "ecr"` the policy carries a second statement allowing the AWS-owned `prod-<region>-starport-layer-bucket`, because that is where ECR keeps image layers and a Fargate pull fetches them straight through this endpoint. That allowance is a bucket we cannot inspect or reason about, sitting inside our only egress — and deleting it, not the ~$32/month, is the actual point of Phase 8.

**Under `registry_mode = "s3"` it is gone.** Verified live on 2026-08-14: the applied policy is a single `OwnBuckets` statement naming `sovran-<account>-*` and nothing else. That closes `WEAKNESSES.md` #2 and PLAN.md §6.2 — the difference between "we don't route to the internet" and "the data plane rejects anything off-path".

If image pulls under `"ecr"` ever start failing with `CannotPullContainerError`, rule this out first: AWS may have renamed the layer bucket. Set `s3_endpoint_policy = false` to unblock, then fix the ARN.

Client buckets and the registry bucket also carry an `aws:SecureTransport = false` deny, so non-TLS access is rejected by the data plane rather than merely never attempted.

### Phase 8 — images from S3 instead of ECR

`registry_mode = "s3"` serves the container images as static objects from a bucket in the
reference account, reached over the free S3 gateway endpoint. A registry pull is only two
GETs — `/v2/<repo>/manifests/<ref>` and `/v2/<repo>/blobs/<digest>` — and S3 can serve both.

What it removes, all verified live on 2026-08-14 in eu-west-2:

- the `ecr.api` and `ecr.dkr` interface endpoints (**$32/month**, leaving `logs` as the only one);
- all three ECR repositories;
- every `ecr:*` permission on the ECS execution role, replaced by **nothing** — an S3 registry pull is anonymous, so no permission is needed to perform it. The role is down to a single `Logs` statement;
- the `prod-<region>-starport-layer-bucket` allowance on the gateway policy.

Both per-client agent services reached steady state running the real three-container task
(`sync-down` init → `agent` → `sync-up`), every image pulled by digest, and `netcheck` — itself
pulled from S3 — asserts both ECR hostnames are now unreachable.

**The two documented risks did not materialise.** containerd *does* request `/v2/`, but a plain
`{}` with no `Docker-Distribution-Api-Version` header satisfies it; and it never asks for the
`Docker-Content-Digest` header S3 cannot send, so **digest and tag pulls both work** on Fargate.

**Block Public Access stays fully on.** The bucket policy grants anonymous `s3:GetObject`
conditioned on `aws:SourceVpce`, which S3 treats as a non-public grant: `PutBucketPolicy` was
accepted with `BlockPublicPolicy = true`, `get-bucket-policy-status` returned `IsPublic: false`,
and fetching a manifest anonymously from the public internet returned **403**.

```bash
aws s3api get-bucket-policy-status --bucket "$(terraform output -raw registry_bucket)"
```

**The security ledger, stated plainly.** This is not free:

- Any process in the VPC can read every image layer anonymously — including the
  credential-free `agent` container reading the `sync` container's source. Not a credential
  leak, but a posture regression that compounds `WEAKNESSES.md` #1, and the price of closing #2.
- "Anonymous read is VPCE-gated" is **not** "only the VPC can read this bucket". The statement
  is an `Allow`, and Allows are additive: IAM principals in this account keep whatever S3
  access their own policies grant them, from anywhere, exactly as with every other bucket here.
  The VPCE condition governs the anonymous grant, which is the one Phase 8 adds.
- The registry bucket is SSE-S3, not SSE-KMS, and must stay that way. An anonymous caller
  cannot hold `kms:Decrypt`, so an SSE-KMS object is unreadable to the image puller and every
  pull would fail. The contents are container images, not client data.

`registry_mode` defaults to **`"s3"`** as of 2026-08-14, when the demo above passed. `"ecr"`
is a one-variable revert and is still built and tested. Changing it either way is a
destroy-and-recreate of the ECR repos and both endpoints, so do it on a torn-down stack,
not mid-demo.

### `bucket_encryption` is a create-time choice

`bucket_encryption` (default `aws:kms`) picks the per-client bucket default encryption:

| Value | Effect |
|-------|--------|
| `aws:kms` | Per-client CMK — a second, independent authorization boundary on top of the bucket policy. This is the isolation story; keep it for anything demo-facing. |
| `AES256` | SSE-S3, no key created. Simpler and faster to tear down and rebuild. Drops the per-client key boundary. |

Neither setting needs a KMS endpoint (see above), and the saving is ~$1/month — this is a simplicity knob, not a cost knob.

**Do not flip it on a live stack.** Existing objects are not re-encrypted; they keep referencing a CMK that Terraform is about to delete, and the task role loses `kms:Decrypt` in the same apply — so `sync-down` fails immediately and the objects are unrecoverable once the 7-day window closes. Destroy the client's buckets first (they are `force_destroy = true`).

**Verifying it actually took effect.** Check the objects, not just the bucket — the two can disagree:

```bash
aws s3api get-bucket-encryption --bucket "$DATA_BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0]'
aws s3api head-object --bucket "$DATA_BUCKET" --key documents/hello.txt \
  --query '[ServerSideEncryption,SSEKMSKeyId]' --output text
```

On the 2026-08-14 verification apply these disagreed: the bucket default was the CMK while both seed objects were `AES256`. `aws_s3_object` only implicitly depends on the bucket, so Terraform raced the uploads against `aws_s3_bucket_server_side_encryption_configuration` and won. Nothing failed — the objects were readable and the agent came up — so the only symptom was `head-object` disagreeing with `get-bucket-encryption`. Fixed with explicit `depends_on` in `reference-client/kms_s3.tf`; the check above is worth keeping, because this class of bug is silent by construction.

Objects written at runtime by `sync-up` were never affected — by then the bucket default is long since in place, and transcripts land as `aws:kms` under the client CMK with `BucketKeyEnabled`.

### Destroy order (Phase 3)

```bash
# 1) client accounts first (VPCE + EC2)
cd infra/envs/client-b && terraform destroy
cd infra/envs/client-a && terraform destroy

# 2) reference (all clients + model + network)
cd infra/envs/reference
aws ecs update-service --cluster sovran-ref --service sovran-alpha-agent \
  --desired-count 0 --region eu-west-1 || true
aws ecs update-service --cluster sovran-ref --service sovran-beta-agent \
  --desired-count 0 --region eu-west-1 || true
terraform destroy
```

ECR repos use `force_delete = true` so destroy can remove non-empty image registries. Buckets use `force_destroy = true` for PoC teardown.

- Prefer **destroy** after demos when possible.  
- Scale-to-zero without a full destroy: `model_asg_desired = 0` and `agent_desired_count = 0` remove the compute but leave the endpoints, ALB and NLBs billing. At the Phase 6 defaults that floor is ~$48/month of endpoints plus the load balancers — cheaper than a GPU, not free.  
- **Do not** enable GPU capacity in a shared/bill-sensitive account without an explicit operator decision.

## Demo sketch (after Phase 2+)

1. SSM to client-a EC2 (no SSH).  
2. HTTP to the agent via that client’s PrivateLink endpoint.  
3. Agent calls **internal** model LB only.  
4. Session artifacts appear under that client’s data bucket (`sessions/…`).  
5. Phase 3: prove client-a cannot reach client-b service/buckets and agent has no internet egress.

## Tagging (Phase 6 standard)

Implemented via `local.base_tags` in each module, merged onto every taggable resource alongside a
per-resource `Name` and `Component`. ASG instances and volumes get them through
`propagate_at_launch` / `tag_specifications`.

| Tag | Example |
|-----|---------|
| `Project` | `sovran` |
| `Client` | `alpha` / `beta` / `platform` |
| `Component` | `agent` / `model` / `endpoint` / … |

## Related docs

- [`../PLAN.md`](../PLAN.md) — architecture, phases, threat model
- [`../SECURITY.md`](../SECURITY.md) — what the proof enforces, and what it does not
- [`../README.md`](../README.md) — what this repository is
- Product site: [sovran.uk](https://sovran.uk)  
