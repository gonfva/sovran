# Sovran — Reference Architecture PoC Plan

**Status:** Agreed approach for implementation (discussion history is *not* required to execute this file).  
**Working title:** Sovran (slug: `sovran`). Final product name TBD: Sovran / Sovereign Runtime / SovRanTime.  
**Mode:** This document is the single source of truth for building the PoC.  
**Do not implement** until an operator explicitly requests implementation of a named phase.

---

## 1. Purpose

Build a **privacy-preserving agent + inference reference architecture** on AWS that demonstrates:

1. Client workloads reach agents only via **cross-account PrivateLink** (no public agent URL required).  
2. Agents and model serving have **no general internet egress** (no NAT on those subnets).  
3. Inference uses a **private model plane** (stub first; self-hosted vLLM + small Gemma later)—not third-party model APIs.  
4. **Two client accounts** cannot access each other’s buckets, keys, or endpoint services.  
5. Session/debug artifacts live as **client data in S3**, not as prompt bodies in shared platform logs.

This is a **PoC / reference architecture**, not a production multi-tenant SaaS control plane.

---

## 2. Non-goals (explicit)

- Self-managed **Firecracker** / OpenClaw Pool-style host density  
- Amazon **S3 Files**, s3fs, or Mountpoint as the primary data path  
- Third-party model APIs (Bedrock, OpenAI, etc.)  
- Account vending / AWS Organizations automation (accounts **already exist**)  
- Hierarchical department RBAC product  
- Multi-region HA, live migration, spot fleet optimization  
- Building the marketing site before infra phases complete  
- Production guarantees, formal compliance certification  

---

## 3. Preconditions

| Prerequisite | Detail |
|--------------|--------|
| **Accounts** | Three AWS accounts already created: `reference`, `client-a`, `client-b` |
| **Credentials** | Local AWS CLI **profiles** for each (names configurable; e.g. `sovran-ref`, `sovran-client-a`, `sovran-client-b`) |
| **Permissions** | Profiles can create VPC, ECS, EC2, IAM, S3, KMS, ELB, VPC endpoints, endpoint services in their account |
| **Region** | Single region chosen at apply time (prefer one with GPU quota if Phase 5 is in scope) |
| **Tooling** | Terraform ≥ 1.5, AWS CLI v2, Docker (for image build), Packer (Phase 5 only) |

---

## 4. High-level architecture

```
┌──────────────────────────┐   ┌──────────────────────────┐
│ client-a account         │   │ client-b account         │
│ VPC + IGW                │   │ VPC + IGW                │
│ EC2 (SSM only, no SSH)   │   │ EC2 (SSM only, no SSH)   │
│ Interface VPC endpoint ──┼───┼── Interface VPC endpoint │
└────────────┬─────────────┘   └────────────┬─────────────┘
             │ PrivateLink                  │
             └──────────────┬───────────────┘
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ reference account                                           │
│ VPC (no NAT for agent + model tiers)                        │
│                                                             │
│  [endpoint subnets]     [agent subnets]     [model subnets] │
│  VPC endpoints          ECS per client      Model ASG/stub  │
│  Per-client NLB +       3-container tasks   Internal model  │
│  endpoint services      → model LB only     LB (internal)   │
│                                                             │
│  Per client: CMK, code bucket, data bucket                  │
└─────────────────────────────────────────────────────────────┘
```

### 4.1 Trust boundaries

| Boundary | Mechanism |
|----------|-----------|
| Client A ⟂ Client B | Separate accounts; separate endpoint services (`allowed_principals`); separate KMS keys and buckets |
| Agent ⟂ Internet | Private subnets, no NAT; only VPC endpoints + internal model LB |
| Model ⟂ Internet | Same; model LB internal only—**not** exposed on client PrivateLink |
| Client admin EC2 | May have outbound internet for SSM/admin; **not** part of agent TCB |
| Platform logs ⟂ prompts | App logs metadata only; transcripts under data bucket session prefixes |

### 4.2 Honest limitation (document in FAQ later)

ECS/Fargate: **one task IAM role per task**, shared by all containers. Sync containers use S3; a compromised agent *could* use the same role. Mitigate with least-privilege IAM, no AWS SDK in agent image, no NAT. **True “guest has no cloud credentials”** is future work (host-mediated Firecracker), out of scope here.

---

## 5. Data plane: init + agent + sync-up

**Do not use Amazon S3 Files or s3fs for this PoC.**

Each agent ECS task runs three containers sharing a volume mounted at `/workspace`:

| Container | Role | ECS pattern | AWS API? |
|-----------|------|-------------|----------|
| `sync-down` | Populate workspace from S3 | **init** container; must exit 0 before agent starts | Yes — Get/List (+ KMS) |
| `agent` | HTTP API + tools on local FS | **essential** main container | **No** (by design) |
| `sync-up` | Periodic + final upload | Sidecar; final sync on shutdown | Yes — Put (+ KMS) |

### 5.1 Workspace layout

```
/workspace/
  .ready                 # written by sync-down when complete
  code/                  # from code bucket (treat as read-only in agent)
  documents/             # from data bucket documents prefix
  sessions/<session_id>/ # agent writes transcripts, tool outputs
  out/                   # optional explicit upload staging
```

### 5.2 Session identity

Agent runs as a **long-lived ECS service** (always-on HTTP behind NLB for PrivateLink).  
Session directories use **application session IDs** from the HTTP API (not ECS task IDs).

### 5.3 Task role permissions (per client)

- `s3:ListBucket` on that client’s code + data buckets (prefix-conditioned where possible)  
- `s3:GetObject` on code bucket + data `documents/*` and relevant session prefixes  
- `s3:PutObject` (and related) on data `sessions/*` (and `out/*` if used)  
- `kms:Decrypt` / `kms:GenerateDataKey` on that client’s CMK only  
- **No** access to other clients’ buckets or keys  
- **No** broad `s3:*` or `*`  

Execution role: ECR pull + CloudWatch Logs only.

### 5.4 Agent filesystem jail

Tools may only read/write under `/workspace` (prefer `/workspace/documents` + `/workspace/sessions/<id>`). Reject path escape (`..`, symlinks outside jail).

---

## 6. Networking

### 6.1 Reference VPC

| Subnet tier | Purpose | NAT |
|-------------|---------|-----|
| `endpoint` | Interface VPC endpoint ENIs; PrivateLink NLBs as preferred | No |
| `agent` | ECS agent tasks | **No** |
| `model` | Model ASG or stub; internal model LB | **No** |

Use **at least 2 AZs** for Fargate/ECS practicality.

### 6.2 VPC endpoints (reference) — “reference endpoints”

**Required for no-NAT operation:**

| Endpoint | Type | Why |
|----------|------|-----|
| S3 | Gateway | Buckets + ECR layers |
| ECR API + ECR DKR | Interface | Image pull |
| CloudWatch Logs | Interface | `awslogs` |
| KMS | Interface | SSE-KMS without internet |
| STS | Interface | Common SDK/role needs |

Optional later: Secrets Manager, SSM (if used).

**Endpoint policies:** Prefer restricting S3 gateway to known bucket ARNs (client buckets + ECR/S3 system paths as required).

### 6.3 Security groups (logical)

| SG | Ingress | Egress |
|----|---------|--------|
| `model` | From `agent` SG on model port | To VPC endpoints as needed (or minimal) |
| `agent` | From NLB/PrivateLink target path on agent port | To model SG port; to VPC endpoint connectivity (S3 gateway + interface endpoints) |
| `nlb` / targets | Per AWS PrivateLink patterns | — |
| Client EC2 | **No inbound** | Outbound for SSM + HTTPS (PoC-open OK) |
| Client VPCE | From client EC2 SG on agent port | To endpoint service |

**Model LB is internal.** Clients never hit the model directly.

### 6.4 PrivateLink per client

**Reference account (per client):**

1. NLB (or ALB+NLB pattern) targeting agent ECS service (`awsvpc` / IP targets).  
2. VPC **endpoint service** pointing at that NLB.  
3. `allowed_principals` = that client account (root or specific role ARN).  
4. Connection **accepter** (Terraform) or lab `acceptance_required = false`.

**Client account:**

1. Interface VPC endpoint to that service.  
2. Private DNS or documented endpoint DNS name.  
3. EC2 via SSM runs `curl`/HTTP client against agent.

### 6.5 Client VPC

- IGW + path for SSM to work (public subnet instance **or** private + SSM endpoints—**prefer public subnet + IGW for PoC simplicity**).  
- One small EC2: Amazon Linux, hostname contains client slug, **SSM only**, **no SSH**, no inbound SG rules.  
- Instance profile: `AmazonSSMManagedInstanceCore` (+ optional read-only on that client’s data bucket for debug).

---

## 7. Storage and crypto

### 7.1 Per client (in reference account)

| Resource | Notes |
|----------|-------|
| KMS CMK | One per client; key policy: ref root, agent task role, optional client debug role |
| Code bucket | Name: `sovran-{ref_account_id}-code-{slug}-{rand}`; versioning; SSE-KMS |
| Data bucket | Name: `sovran-{ref_account_id}-data-{slug}-{rand}`; versioning; SSE-KMS |

Data prefixes:

- `documents/` — durable client docs for RAG/tools  
- `sessions/<session_id>/` — transcripts, outputs  

### 7.2 Client debug access

Optional IAM in **client** account + bucket/key policy grant: read-only on **that** client’s data bucket. Not required for agent path.

---

## 8. Compute: model plane

### 8.1 Phase order

1. **Stub model:** tiny HTTP service (ECS Fargate or small EC2) behind **internal** LB; returns fixed/echo completions.  
2. **Real model:** Packer AMI with vLLM + pinned small Gemma weights baked into AMI; GPU ASG registered to same target group pattern; **no runtime HF egress**.

### 8.2 Model ASG notes (later phase)

- Min capacity ≥ 1 while demoing (no scale-to-zero).  
- Health check against vLLM health route.  
- Build AMI in a network that may reach registries; **runtime** model subnet stays locked down.  
- Pin model revision and record license acceptance.

---

## 9. Compute: agent plane

### 9.1 ECS

- Cluster in reference account.  
- Launch type: **Fargate** (preferred).  
- One **service per client** (desired count ≥ 1 for PrivateLink demos).  
- Task definition: three containers (§5), shared volume, port mapping for agent HTTP.  
- Env: `MODEL_BASE_URL`, `CLIENT_SLUG`, `AWS_REGION`, bucket names (for **sync** containers only).

### 9.2 Agent application (image)

- Simple **Python HTTP** server.  
- Calls model at `MODEL_BASE_URL` (OpenAI-compatible or vLLM routes—pick one and stick to it).  
- **Function-calling / tool** style: tools = read_file / write_file under jail (see Gemma function-calling docs for format inspiration).  
- Logs to stdout: `client`, `session_id`, `latency_ms`, `status`, token counts if available—**never** full prompt/completion bodies.  
- Optionally write `sessions/<id>/transcript.jsonl` under `/workspace` for tenant debug (sync-up persists to S3).

### 9.3 Sync images

- Small images based on AWS CLI or boto3.  
- `sync-down`: manifest-driven or prefix sync; idempotent.  
- `sync-up`: debounce interval (e.g. 30s) + final sync on signal; do not upload `.ready` secrets; exclude junk.

---

## 10. Repository layout (target)

```
.
├── PLAN.md                 # this file
├── README.md               # what this repository is, and where the product site lives
├── SECURITY.md             # what the proof does and does not enforce
├── infra/                  # Terraform root(s)
│   ├── README.md           # apply order, profiles, destroy, costs
│   ├── config.example.hcl  # or tfvars: profile names, account ids, region, slugs
│   ├── modules/
│   │   ├── reference-core/
│   │   ├── reference-client/
│   │   └── client/
│   └── envs/               # or roots: ref, client-a, client-b
├── images/
│   ├── agent/
│   ├── sync/
│   └── model-stub/
└── packer/                 # Phase 5 only
    └── model-ami.pkr.hcl
```

The marketing site is published at https://sovran.uk and is not part of this repository.

Terraform uses **provider aliases** or separate roots with different `profile =` values. Do not create AWS accounts in code.

---

## 11. Configuration contract

Example shape (implementer chooses HCL/tfvars/yaml):

```hcl
region = "eu-west-1"
project_slug = "sovran"

profiles = {
  reference = "sovran-ref"
  client_a  = "sovran-client-a"
  client_b  = "sovran-client-b"
}

clients = {
  a = { slug = "alpha", account_id = "111111111111" }
  b = { slug = "beta",  account_id = "222222222222" }
}

reference_account_id = "333333333333"
```

No long-lived secrets in git. Image tags and AMI IDs as variables.

---

## 12. Phased delivery

Implement **in order**. Each phase has exit criteria. Do not skip isolation proofs.

### Phase 0 — Bootstrap docs and config skeleton

- [x] `infra/README.md` describing profiles and apply order  
- [x] `config.example` with profile keys (`infra/config.example.hcl`)  
- [x] Confirm three profiles work (`aws sts get-caller-identity --profile …`)

**Exit:** Operator can authenticate to all three accounts.

---

### Phase 1 — Reference core network + stub model

**Account:** reference only.

- [x] VPC, 3 subnet tiers × ≥2 AZs  
- [x] No NAT for agent/model route tables  
- [x] Reference endpoints: S3, ECR, Logs, KMS, STS  
- [x] ECS cluster  
- [x] Stub model service + **internal** model LB  
- [x] Security groups as in §6.3  

**Exit:**

- [x] Task in agent subnet can `curl` model health **success**  
- [x] Same task cannot reach public internet (e.g. `curl https://example.com` **fails**)  

**Implemented:** `infra/modules/reference-core`, `infra/envs/reference`, `images/model-stub`, `images/netcheck`. See `infra/README.md` for apply / image push / netcheck / destroy.  

---

### Phase 2 — First client vertical slice (stubs OK)

**Accounts:** reference + client-a.

**Reference:**

- [x] CMK + code/data buckets for client-a  
- [x] Task roles + execution role  
- [x] Task definition: sync-down, agent (stub OK), sync-up  
- [x] ECS service in agent subnets  
- [x] NLB + target group + VPC endpoint service (allow client-a account)  
- [x] Accepter if needed (`acceptance_required = false` for lab)  

**Client-a:**

- [x] VPC, EC2 SSM host, endpoint to service  
- [x] SG rules  

**Exit:**

- [x] From client-a EC2 (SSM): HTTP to agent via PrivateLink **success**  
- [x] Agent reaches stub model **success**  
- [x] Object appears under client-a data bucket after a session (sync-up works)  

**Implemented:** `infra/modules/reference-client`, `infra/modules/client`, `infra/envs/client-a`, `images/agent`, `images/sync`. Operator steps in `infra/README.md`.  

---

### Phase 3 — Second client + isolation

- [x] Same as Phase 2 for client-b via `for_each` / module (`module.clients` + `var.clients` map)  
- [x] Documented isolation tests (see `infra/README.md` Phase 3):

| Test | Expected | Result |
|------|----------|--------|
| Client-a endpoint → client-b service | Fail / not routable | PASS |
| Task role A GetObject on B data bucket | AccessDenied | PASS (`implicitDeny`) |
| Task role B GetObject on A data bucket | AccessDenied | PASS (`implicitDeny`) |
| Agent task egress to internet | Fail | PASS (netcheck) |

**Exit:** Adding a third client is “new map entry + apply,” not a fork of Terraform.  

**Implemented:** `module.clients` `for_each = var.clients` in `infra/envs/reference`; `infra/envs/client-b`; isolation steps in `infra/README.md`.

---

### Phase 4 — Real agent image

- [x] `images/agent` Python HTTP + model client + filesystem tools + jail  
- [x] `images/sync` down/up scripts  
- [x] Push to ECR in reference (via private pull path)  
- [x] Transcript on workspace; CW without prompt bodies  
- [x] Minimal API: create session, chat/turn, list session files  

**Exit:**

- [x] End-to-end tool use reads/writes documents; transcript in `sessions/` in S3  

**Implemented:** agent v0.4 (`jail.py`, `tools.py`, `model_client.py`, `loop.py`, `app.py`); model-stub v0.2 tool_calls; sync exclude junk. API: `GET /health`, `POST/GET /v1/sessions`, `POST …/chat|turn`, `GET …/files`, `POST /v1/demo`.

---

### Phase 5 — Real model AMI (optional for “full” demo)

- [x] Packer: vLLM + pinned Gemma small model in AMI (`google/gemma-4-E2B-it`, vLLM 0.19.1, tool-call-parser gemma4)  
- [x] GPU instance type + ASG + target group (`g5.xlarge`, **max_size=1**)  
- [x] Model LB forwards to the GPU target group (Fargate stub removed entirely)  
- [x] Still no NAT on model subnet at runtime  

**Exit:** Real completions; cost/latency noted in `infra/README.md`.  

**Status (2026-08-13): PHASE 5 COMPLETE. Gates A–E all pass, end to end on real hardware.**

Gate E, with the GPU launched by the ASG itself (`i-0f5e5ae9cad743f27`, eu-west-1a):

| Check | Result |
|---|---|
| ASG placement → ALB target `healthy` | **885 s**, unattended |
| netcheck in agent subnets | **exit 0** — model reachable AND internet blocked |
| client-a EC2 → PrivateLink → agent → model LB → completion | **HTTP 200 in 2.8 s**, 3 turns, **4 tool calls** |
| Transcript in client data bucket | `sessions/541b26562b4a4dad/` — `transcript.jsonl`, `meta.json`, `agent_note.txt` |
| Agent platform logs | 160 events, **0** containing prompt bodies or file contents |

**Cost/latency note:** `g5.xlarge` ≈ $1.2/hr dominates; the control plane (interface
endpoints, ALB, per-client NLBs, Fargate agent, client EC2) is ≈ $0.40/hr. A 3-turn tool-using
exchange over cross-account PrivateLink completes in **~2.8 s**. Cold start is ~15 min from ASG
placement, so this is a demo-on-demand architecture, not something to leave running.

**One real bug found only at this gate:** the agent image defaults `MODEL_NAME` to
`sovran-stub` (a leftover from the removed Fargate stub) and the task definition never set it,
so every completion failed `404 model does not exist` while `/health`, PrivateLink, ECS and the
S3 sync all still looked green. Now passed explicitly as `var.model_name`, defaulting to the
served id `/opt/sovran/models/gemma-4-E2B-it`. Nothing before Gate E could have caught it.

Gate D, on `ami-0e47495c44fb7796f` launched from the ASG's own launch template into model
subnet `10.0.22.0/24` (eu-west-1c), no public IP, reached over SSM only:

| Milestone | Elapsed from `run-instances` |
|---|---|
| SSM registered (proves ssm/ssmmessages/ec2messages work with no NAT) | 60 s |
| Model prewarmed — 9802 MiB at **14 MiB/s** | 673 s |
| vLLM process started | 716 s |
| **`/health` 200** | **1002 s** (16.7 min) |
| ALB target `healthy` after registration | +30 s |

Completion returned `finish_reason: stop`; tool call parsed to
`get_weather({"city": "Dublin"})`; internet egress from the model subnet still fails.
**Privacy invariant verified live**: a canary string sent in a prompt appears **0 times** in
`/sovran/model/vllm` (control term `prewarm` matched, so the search was valid) — CloudWatch
carries only `POST /v1/chat/completions` access lines, no bodies.

`health_check_grace_seconds = 2400` is sound: 2.4× headroom over the measured 1002 s.

**Snapshot hydration is now the dominant cold-start cost** — 673 s of the 1002 s is first-touch
reads of AMI snapshot blocks at 14 MiB/s, nowhere near the volume's provisioned 6000 IOPS /
500 MB/s, because those blocks are faulted in from S3 on first access. The launch template's
IOPS/throughput settings cannot fix this; the direct levers are EBS **volume initialization
rate** or Fast Snapshot Restore. Do not spend more on gp3 provisioning here.

Earlier gates, for the record: vLLM **0.27.1** on Python 3.12, `google/gemma-4-E2B-it` at
revision `3e22461f…`, healthy in 451 s on a debug host, then **rebooted with every
security-group egress rule revoked and came up healthy unattended in 225 s**. Context runs at
the **full native 131072** for the same GPU memory as 4096 (9.59 GiB weights + 8.9 GiB KV; an
18k-token prompt served).

**`g5.xlarge` capacity in eu-west-1 is genuinely scarce**: on 2026-08-13 all three AZs returned
`InsufficientInstanceCapacity`, and placement only succeeded on the third retry ~4 minutes
later. `az_count` is now **3** so the ASG has three subnets to try. Note the AWS error's
"you can currently get capacity by choosing X" hint is boilerplate listing the AZs you did not
ask for — it is not a signal about where capacity exists.

**Original problem — no AMI had ever served a token:**

- Quota is now **4 G/VT vCPU in `reference`/eu-west-1** = exactly one `g5.xlarge`. (`g6.xlarge` is not offered in eu-west-1 at all; G quota is per-region, so the model plane stays on A10G here.)
- Both existing AMIs are unvalidated: `ami-076b31d6a273f6b7a` (vLLM 0.19) and `ami-03ce9a122f75e2cc0` (vLLM 0.26, an 18-minute bake). `04-smoke-local.sh` used to exit 0 on a GPU-less builder, so a bake could "succeed" without vLLM ever starting. It now hard-fails, and AMI names carry `-validated-` / `-UNVALIDATED-`.
- Bring-up is staged so failures are readable before the ASG is involved: debug host → same host rebooted with zero egress → validated bake → manual launch into a model subnet (SSM + CloudWatch journal) → ASG. See `infra/README.md` Phase 5 and `packer/README.md`.
- Model-plane logs now ship to `/sovran/model/vllm` over the Logs interface endpoint, with vLLM request logging suppressed so §14's no-prompt-bodies rule still holds.
- Upstream ships Gemma 4 on **pre-release** vLLM wheels; the bake defaults to the nightly index, and the local vLLM source patches should be dropped if the nightly no longer needs them.

HF token via `export HF_TOKEN=...` only (not Terraform).

---

### Phase 6 — Endpoint diet, hardening and operator UX

The no-NAT design pays for every AWS API it needs via interface VPC endpoints, billed **per ENI per hour** (~$8/AZ/month each in eu-west-1). Phases 0–5 accumulated eight of them across three AZs — ~$193/month standing, for a PoC that is destroyed between demos. Reading every container image shows most of that spend has **no in-VPC caller at all**.

**Endpoint diet**

- [ ] `endpoint_az_count` (default 2, floor of 2): endpoint ENIs need not follow `az_count`, which is 3 only because g5 capacity forced the *model* tier into a third AZ. Private DNS resolves cross-AZ. A one-AZ endpoint tier is **out of scope by decision** — it makes a single AZ a hard dependency for image pulls and log shipping, which is not a trade worth ~$8/month.
- [ ] `model_ssm_access` (default **false**): the `ssm`/`ssmmessages`/`ec2messages` trio exists purely for GPU bring-up debugging; nothing uses it at runtime. Gate the endpoints **and** the instance-role attachment together — one without the other is a silent half-configuration. Set it `true` in the same apply as `model_asg_desired = 1` for any new or unvalidated AMI.
- [ ] Delete the `kms` and `sts` endpoints outright. Neither has an in-VPC caller: SSE-KMS is decrypted inside S3 (service-side), and task credentials come from the ECS credential endpoint (link-local) with EC2 credentials from IMDS. The `sts:AssumeRole` strings in `iam.tf` are trust documents, not API calls.
- [ ] `bucket_encryption` (`aws:kms` | `AES256`, default `aws:kms`): make the per-client CMK optional. This is a **create-time** choice — flipping a live stack destroys the CMK while objects still reference it. Not a cost lever (~$1/month); its value is a faster teardown/rebuild loop. The default keeps the per-client key, which is a second independent authorization boundary and a stated differentiator.
- [ ] Extend `images/netcheck/entrypoint.sh` with `BLOCKED_HOSTS` / `EXPECTED_HOSTS` assertions so a future endpoint re-add is caught by the harness the repo already trusts.

**Original hardening scope**

- [ ] Tighten endpoint policies and bucket TLS denials — the S3 gateway policy can only be *partially* narrowed here (own buckets **plus** the AWS-owned ECR layer bucket); Phase 8 removes that allowance
- [ ] Destroy/scale-down runbook; cost table (endpoints, NLB, GPU)  
- [ ] Architecture diagram in `infra/README.md`  
- [ ] Tagging standard: `Project`, `Client`, `Component`  

**Considered and rejected:** replacing CloudWatch Logs with S3 (FireLens for ECS, a log shipper for the GPU host). It buys ~$8–16/month after the cuts above, but adds `s3:PutObject` to the single shared task role — worsening §4.2's known residual — and to the model instance role, which today has **zero** S3 permissions while seeing every prompt in plaintext. That is precisely the exfiltration channel no-NAT exists to remove. It also collides with `model_ssm_access = false`, where `/sovran/model/vllm` becomes the only window into a GPU that will not go healthy. Rationale recorded in `infra/README.md` because the idea will come back.

**Exit:** Endpoints reduced to `ecr.api` + `ecr.dkr` + `logs` across 2 AZs (~$48/month); netcheck asserts the removed endpoints are unreachable and the retained ones are not; Phase 4 demo passes end to end; cold operator can apply, demo, destroy from README alone.

---

### Phase 7 — Marketing site (late; after architecture stable)

- [x] Marketing site: client-only Svelte app, deployed at sovran.uk (source is not in this repository)  
- [x] Content: reference architecture explanation, FAQ, future steps (Firecracker, credential-free guest, etc.)  
- [x] Deploy to **Cloudflare Pages** (config/docs; domain **sovran.uk**)  
- [x] No secrets; no direct AWS calls required for static explainer  

**Exit:** Public page matches implemented PoC (update copy if infra changed).  

**Implemented:** the marketing site is not in this repository. It is published at https://sovran.uk.

---

### Phase 8 — Remove the ECR endpoints via an S3 static registry (conditional)

After Phase 6 only three interface endpoints remain: `ecr.api`, `ecr.dkr`, `logs`. This phase attempts to delete the two ECR endpoints by serving the container images from S3 as a read-only Docker registry, reached over the **free** S3 gateway endpoint.

**The real prize is not the ~$32/month.** It is §6.2 and `WEAKNESSES.md` #2: the S3 gateway policy cannot be narrowed to our own buckets today, because ECR layer pulls require an AWS-owned `prod-<region>-starport-layer-bucket` we cannot reason about. With ECR gone, the policy names exactly our buckets — the difference between "we don't route to the internet" and "the data plane rejects anything off-path." The execution role also loses its ECR permissions and gains nothing, since the pull is anonymous.

- [x] **8.0 — Decisive spike first, zero Terraform.** Two mechanisms can kill this and neither is knowable from documentation, because Fargate's image puller is closed AWS code:
  - `Docker-Content-Digest` cannot be set on an S3 object. *Mitigated by pulling by digest*, so tag resolution never happens — test digest pulls first.
  - A `/v2/` ping that checks `Docker-Distribution-Api-Version` would be unsatisfiable, with no workaround. containerd does not require it; the classic Docker daemon did.

  Gate on `get-bucket-policy-status` returning `IsPublic: false` for a `Principal: "*"` + `aws:SourceVpce` policy — Block Public Access must stay on. Then push the ~10 MB netcheck image to a scratch bucket, run one task, read `stoppedReason`.
- [x] **8.1 — Implementation, only if the spike passes.** `registry_mode` (`ecr` | `s3`, default `ecr`); count-gate the ECR repos and the two endpoints; a VPCE-gated registry bucket; digest-pinned image references replacing tag variables; a push script rendering the OCI layout with per-object content types.
- [x] **8.2 — Narrow the S3 gateway policy** to our own buckets only.

**If the spike fails, revert Phase 8.** Keep ECR, stay at the Phase 6 end state, and record the exact `stoppedReason` in `infra/README.md` so nobody re-runs the experiment. Reducing AZs is **not** the consolation prize. Reverting is cheap by construction: `registry_mode` was written to default to `ecr`, so an unproven S3 path was dormant rather than load-bearing — which is why 8.0 came first. (The default moved to `s3` once the spike and the full demo had both passed; the revert is still one variable.)

**Honest trade if it succeeds:** a VPCE-gated anonymous-read bucket means any process in the VPC can read every image layer, including the credential-free `agent` container reading the `sync` container's source. Not a credential leak, but a posture regression that compounds §4.2 — and the price of closing §6.2.

**Exit:** agent tasks reach steady state pulling by digest with zero ECR endpoints and no ECR permissions on the execution role; Phase 4 demo passes; netcheck asserts `api.ecr` is now unreachable; the gateway policy names only our buckets and the registry bucket still reports `IsPublic: false`.

**Result (2026-08-14, eu-west-2, live):** the spike passed and neither documented risk materialised. containerd *does* request `/v2/`, but a plain `{}` with no `Docker-Distribution-Api-Version` header satisfies it, and it never asks for `Docker-Content-Digest` — pulls by **digest and by tag** both worked on Fargate. `PutBucketPolicy` was accepted with `BlockPublicPolicy = true` and `get-bucket-policy-status` returned `IsPublic: false`; the same manifest fetched anonymously from the public internet returned **403**.

Implemented and verified end to end: both per-client agent services reached steady state running the real three-container task (`sync-down` init → `agent` → `sync-up`), every image pulled from S3 by digest, with **zero** ECR repositories, **zero** ECR endpoints and **zero** `ecr:*` on the execution role — which is down to a single `Logs` statement. netcheck, itself pulled from S3, now asserts both `api.ecr` and `<account>.dkr.ecr` are unreachable. The gateway endpoint policy is one statement naming `sovran-<account>-*` and nothing else: **§6.2 and `WEAKNESSES.md` #2 are closed.** One interface endpoint remains (`logs`), i.e. the $16/month row.

That condition for flipping the default — the Phase 4 demo running over PrivateLink against a live GPU on `s3` — was met the same day, on a g6.xlarge in eu-west-2: three turns, four tool calls through Gemma 4, transcripts landing under the client CMK. **`registry_mode` therefore now defaults to `s3`.** `ecr` remains a one-variable revert and is still built and tested.

---

## 13. Acceptance criteria (PoC done)

The PoC is complete when all of the following hold:

1. Two clients, three accounts, profile-based Terraform.  
2. Each client reaches **only** its agent over PrivateLink from its EC2.  
3. Agents call **only** the internal model LB.  
4. No NAT on agent/model tiers; internet egress from agent fails.  
5. Per-client KMS + code/data buckets; cross-client S3 access denied.  
6. Init/sync/agent container pattern in use (not S3 Files).  
7. Metadata-only platform logs; session data in client data bucket.  
8. `infra/README.md` sufficient for apply/demo/destroy.  
9. (Optional stretch) Real vLLM+Gemma AMI.  
10. (Optional stretch) Svelte site on Cloudflare Pages.

---

## 14. Threat model (short)

| Threat | PoC control |
|--------|-------------|
| Cross-client data read | Accounts + bucket/key isolation + EPS allowlist |
| Agent prompt to public LLM API | No NAT; no credentials to SaaS models |
| Agent open-internet exfil | No NAT |
| Prompt leakage via CloudWatch | Logging policy in agent code |
| Confused deputy on S3 | Prefix + per-client role; never shared role across clients |
| Client admin compromise | Limited to that client’s debug role / EC2 |
| Task role abuse by agent process | Soft mitigations only (§4.2)—accepted PoC residual risk |

---

## 15. Cost awareness

Expect non-trivial **idle** cost from: interface VPC endpoints, per-client NLBs, optional GPU ASG, three-account sprawl.  
`infra/README.md` must tell operators how to **destroy** or scale to zero after demos.

Interface endpoints are the largest idle line and are billed **per ENI per hour** — $0.011/hr in eu-west-1, i.e. **$8.03 per AZ per month per endpoint**. Multiply by endpoints *and* AZs:

| State | Endpoints × AZs | $/month |
|---|---|---|
| Phases 0–5 as built | 8 × 3 | **193** |
| After Phase 6 | 3 × 2 | **48** |
| After Phase 8, if the spike passes | 1 × 2 | **16** |

The GPU ASG dominates when running (`g5.xlarge`, on-demand) and is the reason `model_asg_desired` defaults to 0.

---

## 16. Naming

| Use | Value until product name freezes |
|-----|----------------------------------|
| Working title | Sovran |
| Resource slug variable | `sovran` (overridable) |
| Domains under discussion | sovran.uk / sovrantime.com — **not** required for infra |

When the name freezes: change README + site; keep `project_slug` if resources already applied.

---

## 17. Implementation instructions for agents

1. Read **only this file** + existing repo tree.  
2. Implement **one phase at a time**; stop at phase exit criteria.  
3. Do not expand scope into Firecracker, S3 Files, or the Svelte site early.  
4. Prefer readable Terraform over clever abstractions; modules: `reference-core`, `reference-client`, `client`.  
5. Never commit real account credentials; use profiles from config.  
6. If AWS behavior differs from this plan, document deviation in `infra/README.md` and prefer **least privilege + no NAT**.  
7. Ask the human before: destroying unknown resources, purchasing domains, or enabling costly GPU capacity in a shared account.

---

## 18. Phase dependency graph

```
Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 6 → Phase 8 (conditional)
                       │                   │
                       │                   └→ Phase 5 (optional, can start after 4)
                       │
                       └→ Phase 7 (site) only after 4+6 stable (5 optional)
```

Phase 8 depends on Phase 6 and is revertible to it. Phase 7 shipped ahead of Phase 6 because the site was gated on Phase 5 proving real inference, not on endpoint hardening.

---

*End of plan. This repository is the proof. The product site is https://sovran.uk.*
