# Packer — model AMI (Phase 5)

Builds an AMI with **vLLM** (nightly by default) and **baked** `google/gemma-4-E2B-it` weights.

Upstream's [Gemma 4 recipe](https://docs.vllm.ai/projects/recipes/en/stable/Google/Gemma4.html)
installs a **pre-release** wheel, so that is the default here (`vllm_pre_release=true`,
`vllm_index_url=https://wheels.vllm.ai/nightly`, `vllm_version=""` → latest). Released wheels
through 0.27.1 need `03b-patch-gemma4-head-dim.sh` to patch vLLM's own Gemma 4 head_dim handling;
if the nightly serves without it, drop the patch rather than maintaining it. **Once a version is
proven on a debug host, pin it** with `-var "vllm_version=<resolved>"` so bakes stop moving.

## The AMI tells you whether it works

`04-smoke-local.sh` starts vLLM during the bake and requires **both** a chat completion **and** a
parsed `tool_calls` response before the AMI is snapshotted. A builder without a usable GPU is now a
hard failure, not a silent pass. The result is visible in the artifact itself:

| Name contains | Meaning |
|---|---|
| `-validated-` | vLLM served a completion and a tool call on a real GPU during the bake |
| `-UNVALIDATED-` | `-var skip_gpu_smoke=true` was passed. **Never wire this into `terraform.tfvars`** |

`/opt/sovran/build-info.txt` on the AMI records resolved versions, `validated=`,
`tool_call_smoke=`, and `smoke_ready_seconds=`; `/opt/sovran/requirements.lock.txt` is the full
`pip freeze` of the venv.

**Base image is always Amazon Deep Learning AMI (AL2023 + NVIDIA)** — never an older Sovran AMI.

Runtime model subnets stay **no-NAT**; weights are not downloaded at boot.  
Packer is **not** run by Terraform. Operators build the AMI, then pass `model_ami_id` into `infra/envs/reference`.

## Prerequisites

- Packer ≥ 1.10  
- **GPU bake must run in the reference account** (On-Demand G and VT ≥ 4). Client accounts often still have GPU quota 0.  
- Public subnet with IGW (**reference default VPC**, not the private Sovran VPC)  
- Hugging Face token:

  ```bash
  export HF_TOKEN=hf_...
  ```

## Network: where to build

| Network | Internet | GPU quota | Use for |
|---------|----------|-----------|---------|
| Reference **default VPC** public subnets | Yes (IGW) | Yes (ref account) | **GPU bake + SSH debug** |
| Reference Sovran VPC (endpoint/agent/model) | No on agent/model | Yes | Runtime only — not for Packer |
| Client-a/b public subnets | Yes | Often no | CPU-only bake only |

```bash
export AWS_PROFILE=sovran-ref
export AWS_DEFAULT_REGION=eu-west-1

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters \
  Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)
echo "VPC_ID=$VPC_ID SUBNET_ID=$SUBNET_ID"
```

## SSH debug on Amazon DLAMI (preferred before / during bake)

**Do not** iterate on any old Sovran bake (`ami-076b31d6a273f6b7a` = vLLM 0.19,
`ami-03ce9a122f75e2cc0` = vLLM 0.26, neither ever smoke-tested). Start from **Amazon DLAMI**,
install the **nightly** wheel, then watch:

```bash
sudo journalctl -fu sovran-vllm
```

### Launch

```bash
export AWS_PROFILE=sovran-ref AWS_DEFAULT_REGION=eu-west-1
# Free model ASG if it holds the only G slot:
#   aws autoscaling set-desired-capacity --auto-scaling-group-name <asg> --desired-capacity 0

./packer/launch-debug-host.sh
# defaults to latest Amazon DLAMI; refuses Sovran AMI names
```

```bash
ssh -i ~/.ssh/sovran-packer-debug.pem ec2-user@<public-ip>
```

### On the host

Copy `packer/scripts/` and run with env, or use full Packer bake. Primary signal is the unit journal, not health polling.

**Instance:** default **`g5.xlarge` (24 GB A10G)** — matches vLLM’s Gemma4 E2B “24 GB+” table and 4 vCPU G quota.  
Avoid `g4dn.xlarge` (16 GB T4). Spot G quota is often still 0 — use On-Demand.

## Packer full bake

Defaults: **latest vLLM nightly**, Amazon DLAMI source, `TRITON_ATTN` / `dtype auto` / `max-model-len 4096` / `gpu-memory-utilization 0.85`, text-only `--limit-mm-per-prompt`, Gemma4 tool + reasoning parsers.

### Why ASG cold-start was much slower than the bake smoke

| Factor | Bake (warm) | ASG first boot (cold) |
|--------|-------------|------------------------|
| EBS blocks | Just written / hot | Lazy-loaded from snapshot |
| Triton / torch JIT | First compile during smoke | Reuses `/opt/sovran/cache/*` if baked |
| Model open | Sequential after download | Competes with first-touch I/O |

Mitigations in this tree: `ExecStartPre` model prewarm, bake-time smoke (populates JIT caches), ASG root volume **gp3 500 MB/s / 6000 IOPS**, health grace **40 min**.

**Measured on the first ASG boot of `ami-0560d1d6984a5a248` (g6.xlarge, eu-west-2c, 2026-08-14):**
the prewarm alone took **895 s — 9802 MiB at 10 MiB/s** — before vLLM even started, and weight
loading came on top of that. 10 MiB/s is nowhere near what the volume can do; it is snapshot
hydration, paid once per instance. Do not respond by buying more IOPS: the bake showed 4x the
IOPS bought 5% (see below). Budget **~35-40 minutes** from `desired_capacity = 1` to a healthy
target, and leave the 40-minute health grace alone.

### `03b-patch-gemma4-head-dim.sh`

Required for **released** vLLM 0.26–0.27 when transformers folds `global_head_dim` into `per_layer_config`. Upstream **main** uses `gemma4_layer_config()` and the script no-ops if that is present — so on the default nightly this should print `skipped-upstream-fixed`. **If it does, delete the script and its entry in the Packer `scripts` list** rather than carrying a patch against vLLM internals.

### Interactive Packer debug (SSH between provisioners)

```bash
export AWS_PROFILE=sovran-ref
export AWS_DEFAULT_REGION=eu-west-1
export HF_TOKEN=hf_...

VPC_ID=...   # default VPC
SUBNET_ID=...

cd /path/to/sovran
packer init packer/

# -debug: prints SSH info and pauses at each step (press ENTER to continue).
packer build -debug \
  -var "region=eu-west-1" \
  -var "vpc_id=${VPC_ID}" \
  -var "subnet_id=${SUBNET_ID}" \
  -var "ami_users=YOUR_REFERENCE_ACCOUNT_ID" \
  -var "instance_type=g5.xlarge" \
  -var "use_spot=false" \
  -var "skip_gpu_smoke=false" \
  packer/model-ami.pkr.hcl
```

Packer prints something like `ssh -i /tmp/packer-... ec2-user@x.x.x.x`. Use that and `sudo journalctl -fu sovran-vllm`. Press ENTER in the Packer terminal to resume.

### Non-interactive bake

```bash
packer build \
  -var "region=eu-west-1" \
  -var "vpc_id=${VPC_ID}" \
  -var "subnet_id=${SUBNET_ID}" \
  -var "ami_users=YOUR_REFERENCE_ACCOUNT_ID" \
  -var "instance_type=g5.xlarge" \
  packer/model-ami.pkr.hcl
```

**CPU-only** (no GPU smoke):

```bash
packer build ... -var "instance_type=m5.xlarge" -var "skip_gpu_smoke=true" ...
```

Expect **30–60+ minutes**. AMI ID is printed and written to `packer/manifest.json` (gitignored).

### eu-west-2 / g6.xlarge

`g6.xlarge` (L4, 24GB) does not exist in eu-west-1, and in eu-west-2 it is offered in **all
three AZs** where `g5.xlarge` reaches only two. That AZ coverage — not price or speed — is the
reason to prefer it: Phase 5 lost hours to `InsufficientInstanceCapacity` on g5.

```bash
export AWS_PROFILE=sovran-ref HF_TOKEN=hf_...
packer build \
  -var "region=eu-west-2" \
  -var "vpc_id=$(aws ec2 describe-vpcs --region eu-west-2 --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)" \
  -var "subnet_id=$(aws ec2 describe-subnets --region eu-west-2 --filters Name=availability-zone,Values=eu-west-2a Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)" \
  -var "instance_type=g6.xlarge" \
  packer/model-ami.pkr.hcl
```

Nothing in the scripts is GPU-arch specific. L4 is sm_89 and A10G is sm_86 — both CUDA 12,
both served by the same wheels with no arch flags, and vLLM 0.27.1 picks the same backend
split on the L4 as it did on the A10G (FLASH_ATTN for the 28 sliding layers, FLASHINFER for
the 7 full-attention head_dim-512 layers). Same 24GB, so `MAX_MODEL_LEN=131072` at
`GPU_MEM_UTIL=0.85` carries over unchanged.

**Expect the bake to be slower.** L4 has roughly half the memory bandwidth of A10G (~300 vs
~600 GB/s). Measured 2026-08-14: weight loading alone took ~23 minutes.

**The G quota is per-region and it is 4 vCPU** — exactly one `g6.xlarge`. The Packer builder
consumes all of it, so a bake cannot overlap with `model_asg_desired = 1`. Let the build
finish and terminate before scaling the ASG up.

## Wire into reference Terraform

```hcl
# infra/envs/reference/terraform.tfvars
model_ami_id        = "ami-xxxxxxxx"  # must be a *-validated-* AMI
model_instance_type = "g5.xlarge"
model_asg_desired   = 1

# First bring-up only — keeps a failed instance alive for journalctl over SSM.
model_health_check_type = "EC2"
```

```bash
cd infra/envs/reference
# ASG desired 0 while baking; set 1 after AMI is ready
terraform apply
```

Before trusting the ASG, launch the AMI **by hand** into a model subnet (model SG + model instance
profile, `model_asg_desired = 0`) and read it over SSM. Nothing terminates a manually launched
instance mid-diagnosis.

## Runtime behaviour

- systemd unit `sovran-vllm` on `:8000`, `ExecStart=/opt/sovran/serve.sh`
- **`/opt/sovran/serve.sh` is the command line.** systemd's quoting and line-continuation rules
  used to mangle a multi-line `ExecStart` (an empty optional arg silently dropped the next flag);
  now the unit and a human debugging by hand run the same file
- flags are probed against the installed wheel at bake time (`vllm serve --help`), so a renamed or
  missing flag fails the bake instead of the first boot
- OpenAI-compatible API + `--tool-call-parser gemma4` + `--reasoning-parser gemma4`
- `HF_HUB_OFFLINE=1`, `--dtype auto`
- **attention backend: left to vLLM.** On 0.27.1 / A10G it selects per layer group —
  `FLASH_ATTN` for the 28 sliding layers, `FLASHINFER` for the 7 full-attention layers
  (head_dim 512). `VLLM_ATTENTION_BACKEND=TRITON_ATTN` did not restrict that list, so forcing
  Triton was a no-op inherited from the T4 era. Note this makes **flashinfer load-bearing at
  runtime**, which is why the venv interpreter must be right
- **`--max-model-len 131072`** (full native context). Measured on a 24 GB A10G at util 0.85:
  identical GPU memory to 4096 — 9.59 GiB weights + 8.9 GiB KV cache either way, because vLLM
  pages KV per token actually used. KV holds **1,452,356 tokens** = 11.08x concurrency at full
  length; an 18k-token prompt served fine. The old 4096 came from an `8192@0.90` OOM that was a
  memory-fraction problem, not a context limit
- request logging suppressed (`--max-log-len 0` / `--disable-log-requests`) — the journal ships to
  CloudWatch and prompt bodies must not (PLAN.md invariant)
- `sovran-vllm-log.service` bridges the journal to `/var/log/sovran/vllm.log`, which the
  cloudwatch-agent ships to `/sovran/model/vllm` via the Logs interface endpoint (no NAT)
- `StartLimitBurst=3` in 30 min: a permanently broken engine stops and leaves a readable corpse
  instead of restart-looping through the ASG's whole grace period
- ASG **max_size = 1**; health grace 40 minutes  

## Cost

- One On-Demand `g5.xlarge` at a time (quota ≈ 4 G vCPU)  
- Keep `model_asg_desired=0` or destroy when idle  
- Terminate debug instances when done  

## Lessons from first live GPU run (2026-08-10)

| Symptom | Cause | Fix |
|---------|--------|-----|
| ASG never healthy | Old bake: vLLM **0.19** + transformers **4.x** | Re-bake from **Amazon DLAMI** + **vLLM 0.26** |
| `AmbiguousGlobalPerLayerAttributeError: head_dim` | 0.19 + transformers 5.x / Gemma 4 dual attention | Upgrade to 0.26 (not long-term 0.19 patches) |
| EngineCore / FA2 on T4 | FA2 needs compute ≥ 8.0 | `--attention-backend TRITON_ATTN` |
| Spot launch fails | Spot G quota **0** | On-Demand only |
| `VcpuLimitExceeded` | On-Demand G = 4 vCPU = one g5.xlarge | One instance at a time |
| E2B OOM / undersized GPU | Docs: **24 GB+**; g4dn is 16 GB T4 | Use **g5.xlarge** (24 GB A10G) |
| Health-only waits hide failures | Binary probe | Prefer `journalctl -fu sovran-vllm` |

## Lessons from the 2026-08-12 review

| Symptom | Cause | Fix |
|---------|--------|-----|
| "ASG never worked" | The AMI in tfvars (`ami-03ce9a122f75e2cc0`, 18-minute bake) had **never served a token** — `04-smoke-local.sh` exited 0 on a GPU-less builder | Smoke hard-fails without a GPU; AMI name carries `-validated-` / `-UNVALIDATED-` |
| No idea *why* a boot failed | Nothing shipped the journal off a no-NAT instance; only signal was "ALB target unhealthy" 40 min later | cloudwatch-agent → `/sovran/model/vllm`, plus SSM |
| `--trust-remote-code` silently dropped | Conditional line-continuation in the generated systemd unit | `ExecStart=/opt/sovran/serve.sh` |
| flashinfer "array.array is not subscriptable" patched blind | Measured on the DLAMI: default `python3` is **3.9.25**, where `array.array[int]` genuinely raises; the image ships 3.9 and 3.12 but **no 3.11**, so the old `PYTHON=python3.11; command -v \|\| PYTHON=python3` fallback silently built the venv on 3.9. The library was never the problem | Prefer `python3.12` (already installed); assert the **venv** interpreter ≥3.10; probe the import and only patch if it actually fails |
| Fighting released wheels with source patches | Upstream ships Gemma 4 on pre-release wheels | The nightly index tops out at `0.26.1rc1.dev688` — **older** than the 0.27.1 release, so `--pre` resolves to the same wheel. Pinned to **0.27.1**, which still needs `03b` |
| Context capped at 4096 "because 24 GB is marginal" | An `8192@0.90` OOM was read as a context limit; it was a memory-fraction problem | **131072** (full native) costs the same GPU memory as 4096 — vLLM pages KV per token used |
| `--help` says a flag does not exist | 0.27.1's plain `serve --help` is an 80-line summary; the real 1858-line list is behind `--help=all` | Probe `--help=all` |

## Verified on a live A10G (2026-08-12)

First successful serve in this project — `g5.xlarge`, eu-west-1c, DLAMI `ami-018828caca9da8faf`:

| Check | Result |
|---|---|
| venv interpreter | Python **3.12.13** (DLAMI default `python3` is 3.9; no 3.11 on the image) |
| flashinfer import | clean — the source-rewriting patch is unnecessary on a correct interpreter |
| vLLM | 0.27.1, transformers 5.15.0, torch 2.13.0+cu130 |
| `03b` head-dim patch | **required** (no `gemma4_layer_config` in 0.27.1); applied cleanly |
| first load → `/health` | 451 s (warm volume, cold compile cache) |
| completion + tool call | pass — `get_weather{"city": "Dublin"}` parsed by the gemma4 parser |
| **reboot with all SG egress revoked** | **healthy unattended in 225 s** — no hidden runtime egress |
| 128k context | healthy in 181 s; 18,024-token prompt served |
| Baked AMI | `ami-0e47495c44fb7796f` — `sovran-gemma4-e2b-vllm-0-27-1-validated-20260812-184244`, `Validated=true`, smoke healthy in 1696 s, tool call passed |

## Verified on a live L4 (2026-08-14, eu-west-2)

Second GPU family, first bake outside eu-west-1 — `g6.xlarge`, eu-west-2a, DLAMI
`ami-0791d50743de94d6b`. The point of the exercise was that eu-west-2 offers `g6.xlarge` in
**all three AZs**, where eu-west-1 has no g6 at all and only two AZs of g5.

| Check | Result |
|---|---|
| Attention backends | Identical split to the A10G: **FLASH_ATTN** for the 28 sliding layers, **FLASHINFER** for the 7 full-attention (head_dim 512) layers — sm_89 needed no arch flags or wheel changes |
| `03b` head-dim patch | required and applied cleanly, same as A10G |
| weight loading | ~1380 s (17:00:00 → 17:22:56) |
| first load → `/health` | **1746 s** during the bake smoke |
| completion + tool call | **pass** — the gemma4 parser and chat template work unchanged on L4 |
| 24 GB / 131072 context | unchanged from A10G; same `GPU_MEM_UTIL=0.85`, same KV headroom |
| Baked AMI | `ami-0560d1d6984a5a248` — `sovran-gemma4-e2b-vllm-0-27-1-validated-20260814-165351`, `Validated=true` |

**L4 is slower than A10G, and expectedly so:** ~300 GB/s of memory bandwidth against ~600.
The bake smoke took 1746 s versus 1696 s on the A10G — close, because that phase is not
bandwidth-bound (see below) — but decode is bandwidth-bound and should be assumed slower.
Nothing about capacity or correctness changes; only latency.

### Measured throughput (g6.xlarge / L4, gemma-4-E2B-it, vLLM 0.27.1, 2026-08-14)

Measured on the model host itself against `localhost:8000`, so no ALB, PrivateLink or agent
hop is in the number. `ignore_eos` forces exactly the requested token count. GPU reported
23034 MiB total with 21536 MiB in use — the configured `GPU_MEM_UTIL=0.85`.

| Case | Result |
|---|---|
| Single stream, 256 output tokens | **49.3 tok/s** (5.19 s) |
| Single stream, 512 output tokens | **48.9 tok/s** (10.48 s) |
| Real generation, 1196 tokens (story, natural EOS) | **47.9 tok/s** (24.97 s) |
| Sustained, 2048 tokens (`ignore_eos`) | **47.5 tok/s** (43.09 s) |
| 8 concurrent streams, 256 each | **365.8 tok/s aggregate**, 45.7 per stream (5.60 s) |
| Prefill, 4513-token prompt | 4513 prompt + 16 output tokens in **0.75 s** total |

Two things worth keeping:

**Throughput is flat in output length.** 49.3 tok/s at 256 tokens against 47.5 at 2048 — a
3.7% decline over an 8x longer generation. There is no KV-growth cliff to design around in
this range, so "how long is the answer" is not a capacity question.

**Concurrency is nearly free.** 8 streams cost ~7% per-stream and deliver **7.4x** the
aggregate, so a single conversation is nowhere near saturating this card. Prefill is not the
bottleneck either — subtracting ~0.33 s of decode from the 0.75 s leaves roughly 0.4 s for
4513 prompt tokens, on the order of 10k tok/s.

**Output quality at E2B, sampled the same day:** a 1196-token story held its premise and
landed a real ending; FizzBuzz in Python and Rust was idiomatic in both, with an accurate
note on the iterator-vs-loop difference; and asked to review a function building SQL by
string concatenation, it led with the injection vulnerability. Small model, but not a toy.

**For sizing an agent demo:** a single user sees ~48 tok/s regardless of answer length, and
the box absorbs several concurrent sessions before any of them notices. The 5.1 s the Phase 4
demo takes is three full agent turns including tool calls, not model latency alone.

**One `g6.xlarge` is the entire eu-west-2 G quota** (4 vCPU, measured 2026-08-14). The Packer
builder holds it for the duration of the bake, so `model_asg_desired = 1` cannot overlap with
a build.

### First-load cost is not disk-bound

`Loading weights took ~1290-1350 s` (9.19 GiB ≈ 7 MB/s) on **both** a default gp3 (3000 IOPS /
125 MB/s) and a provisioned one (12000 IOPS / 750 MB/s) — 4x the IOPS bought 5%. The initial
theory (cold 4 KB mmap faults capped by IOPS) does not survive that comparison; the constraint
is in the load path, most plausibly CPU-bound on 4 vCPU. Do not "fix" this by buying more EBS.

For scale, the same model on the same instance type:

| Situation | Time to `/health` |
|---|---|
| First-ever load, empty compile cache (bake) | 1696 s |
| Second load, warm compile cache (debug host) | 451 s |
| After reboot, warm compile cache, cold page cache | 225 s |

The AMI ships the populated `torch.compile` / Triton caches, so an ASG instance should resemble
the last two rows rather than the first — but only Gate D on a snapshot-backed volume gives the
number that should set `health_check_grace_seconds`. The prewarm now prints MiB/s: a rate in the
thousands means page-cache hits, not EBS reads, and those pages get evicted during startup.
