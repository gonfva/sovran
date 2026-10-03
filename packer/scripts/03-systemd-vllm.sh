#!/usr/bin/env bash
# Serve wrapper + systemd unit + log egress for the vLLM model plane.
#
# Aligns with https://docs.vllm.ai/projects/recipes/en/stable/Google/Gemma4.html
# for text-only agent demos on a single 24GB A10G (g5.xlarge):
#   - --limit-mm-per-prompt image=0,audio=0  (skip multimodal towers' prompt memory)
#   - --tool-call-parser gemma4 + --enable-auto-tool-choice
#   - --reasoning-parser gemma4 (needed for thinking mode; leave max_tokens headroom)
#   - attention backend: let vLLM pick. On 0.27.1 it selects per layer group
#     (FLASH_ATTN for sliding, FLASHINFER for the head_dim=512 full layers);
#     VLLM_ATTENTION_BACKEND=TRITON_ATTN did not restrict that choice.
#   - max-model-len 131072 (full native) / util 0.85: measured identical GPU memory
#     to 4096, since vLLM pages KV per token actually used
#
# The command line lives in /opt/sovran/serve.sh, not in ExecStart. systemd's own
# quoting and line-continuation rules used to silently mangle this unit (an empty
# optional argument turned the following flag into a bogus directive), and an
# operator debugging by hand could not run the same command the unit ran. Now they
# are the same file.
#
# Cold-boot note: AMI snapshot blocks hydrate lazily. ExecStartPre pre-reads
# model weights so the first vLLM load is not thrashing on EBS first-touch I/O.
set -euo pipefail

MODEL_DIR="${MODEL_DIR:-/opt/sovran/models/gemma-4-E2B-it}"
VLLM_PORT="${VLLM_PORT:-8000}"
# Empty = let vLLM select (see header). Set only to override.
ATTENTION_BACKEND="${ATTENTION_BACKEND:-}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.85}"
DTYPE="${DTYPE:-auto}"
# vLLM accepts JSON object form for --limit-mm-per-prompt. Upstream's recipe uses the
# key=value form (image=0,audio=0); switch here if a wheel rejects the JSON form.
_DEFAULT_LIMIT_MM='{"image":0,"audio":0}'
LIMIT_MM_JSON="${LIMIT_MM_JSON:-$_DEFAULT_LIMIT_MM}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-/opt/sovran/tool_chat_template_gemma4.jinja}"
LOG_GROUP="${LOG_GROUP:-/sovran/model/vllm}"
VLLM_BIN=/opt/sovran/venv/bin/vllm

# --- Flag support probe -------------------------------------------------------
# vLLM renames server flags between releases, and this AMI may be built from a
# nightly. Ask the installed wheel what it accepts instead of assuming.
echo "==> probing supported server flags"
# vLLM 0.27's plain `serve --help` is an ~80-line summary; the full ~1800-line flag
# list is only behind --help=all. Probing the summary makes real flags look missing.
HELP_TXT=$("$VLLM_BIN" serve --help=all 2>&1) || HELP_TXT=""
if [[ $(wc -l <<<"$HELP_TXT") -lt 100 ]]; then
  HELP_TXT=$("$VLLM_BIN" serve --help 2>&1) || {
    echo "ERROR: '$VLLM_BIN serve --help' failed — vLLM install is broken:" >&2
    echo "$HELP_TXT" | tail -30 >&2
    exit 1
  }
fi
echo "==> help surface: $(wc -l <<<"$HELP_TXT") lines"
has_flag() { grep -q -- "$1" <<<"$HELP_TXT"; }

EXTRA_ARGS=()

# Privacy: PLAN.md forbids prompt/completion bodies in platform logs, and this unit's
# output is shipped to CloudWatch below. In vLLM 0.27, --enable-log-requests logs
# request params at INFO and *prompt inputs at DEBUG*, and --enable-log-outputs logs
# completions. Both default to off, but state it explicitly so a future default flip
# cannot silently start shipping prompts. Fail the bake rather than guess.
PRIVACY_OK=0
if has_flag "--no-enable-log-requests"; then
  EXTRA_ARGS+=(--no-enable-log-requests)
  PRIVACY_OK=1
  if has_flag "--no-enable-log-outputs"; then
    EXTRA_ARGS+=(--no-enable-log-outputs)
  fi
elif has_flag "--disable-log-requests"; then
  # Older wheels: single opt-out flag.
  EXTRA_ARGS+=(--disable-log-requests)
  PRIVACY_OK=1
elif has_flag "--max-log-len"; then
  # Weakest fallback: truncate logged prompt characters. Undocumented semantics in
  # 0.27's help, so only used when no explicit opt-out exists.
  EXTRA_ARGS+=(--max-log-len 0)
  PRIVACY_OK=1
fi
if [[ "$PRIVACY_OK" -ne 1 ]]; then
  echo "ERROR: this vLLM exposes no request-log suppression flag" >&2
  echo "       (--no-enable-log-requests / --disable-log-requests / --max-log-len)." >&2
  echo "       Refusing to bake: journal ships to CloudWatch and prompts must not." >&2
  exit 1
fi

# Optional throughput flag from the Gemma 4 recipe; absent on older wheels.
if has_flag "--async-scheduling"; then
  EXTRA_ARGS+=(--async-scheduling)
fi

echo "==> extra args: ${EXTRA_ARGS[*]:-<none>}"

# --- Pre-warm helper: sequential read of model tree (EBS snapshot hydration) ---
sudo tee /opt/sovran/prewarm-model.sh >/dev/null <<'EOF'
#!/bin/bash
# Read every file under MODEL_DIR once so EBS snapshot blocks are pulled
# before vLLM starts. No-op if directory missing.
set -euo pipefail
MODEL_DIR="${1:-/opt/sovran/models/gemma-4-E2B-it}"
if [[ ! -d "$MODEL_DIR" ]]; then
  echo "prewarm: missing $MODEL_DIR" >&2
  exit 0
fi
BYTES=$(du -sb "$MODEL_DIR" 2>/dev/null | awk '{print $1}')
echo "prewarm: reading $MODEL_DIR ($(( BYTES / 1024 / 1024 )) MiB)"
START=$(date +%s)
# Sequential read of each file so EBS snapshot blocks hydrate before vLLM opens them.
find "$MODEL_DIR" -type f -exec dd if={} of=/dev/null bs=4M status=none \; 2>/dev/null || \
  find "$MODEL_DIR" -type f -exec cat {} + >/dev/null 2>&1 || true
ELAPSED=$(( $(date +%s) - START ))
RATE=$(( BYTES / 1024 / 1024 / (ELAPSED > 0 ? ELAPSED : 1) ))
echo "prewarm: done in ${ELAPSED}s (${RATE} MiB/s)"
# Report the rate rather than just "done": a suspiciously high rate means the pages were
# already cached, which is NOT the same as the blocks being resident on disk-backed EBS.
# Those pages can be evicted during engine startup (16 GiB RAM vs a 9.6 GiB model), after
# which vLLM re-reads them cold as 4KB random mmap faults.
if (( RATE > 2000 )); then
  echo "prewarm: NOTE ${RATE} MiB/s implies page-cache hits, not EBS reads;" \
       "cold-load time will depend on provisioned IOPS, not on this number"
fi
EOF
sudo chmod +x /opt/sovran/prewarm-model.sh
sudo chown ec2-user:ec2-user /opt/sovran/prewarm-model.sh

# --- serve.sh: the one command line, used by systemd and by humans --------------
{
  echo '#!/bin/bash'
  echo '# Generated by packer/scripts/03-systemd-vllm.sh at AMI bake time.'
  echo '# This is exactly what sovran-vllm.service runs. Run it by hand to debug.'
  echo 'set -euo pipefail'
  echo ''
  if [[ -n "$ATTENTION_BACKEND" ]]; then
    echo "export VLLM_ATTENTION_BACKEND=\"\${VLLM_ATTENTION_BACKEND:-${ATTENTION_BACKEND}}\""
    echo ''
  fi
  echo 'ARGS=('
  echo "  serve \"${MODEL_DIR}\""
  echo '  --host 0.0.0.0'
  echo "  --port \"${VLLM_PORT}\""
  echo "  --dtype \"${DTYPE}\""
  echo "  --max-model-len \"${MAX_MODEL_LEN}\""
  echo "  --gpu-memory-utilization \"${GPU_MEM_UTIL}\""
  echo "  --limit-mm-per-prompt '${LIMIT_MM_JSON}'"
  echo '  --enable-auto-tool-choice'
  echo '  --tool-call-parser gemma4'
  echo '  --reasoning-parser gemma4'
  if [[ -f "$CHAT_TEMPLATE" ]]; then
    echo "  --chat-template \"${CHAT_TEMPLATE}\""
  fi
  echo '  --trust-remote-code'
  for arg in "${EXTRA_ARGS[@]}"; do
    echo "  ${arg}"
  done
  echo ')'
  echo ''
  echo "exec ${VLLM_BIN} \"\${ARGS[@]}\""
} | sudo tee /opt/sovran/serve.sh >/dev/null
sudo chmod +x /opt/sovran/serve.sh
sudo chown ec2-user:ec2-user /opt/sovran/serve.sh
echo "==> generated /opt/sovran/serve.sh:"
cat /opt/sovran/serve.sh

# Syntax-check the generated wrapper here, not on first boot in a private subnet.
bash -n /opt/sovran/serve.sh

# --- systemd unit --------------------------------------------------------------
sudo mkdir -p /var/log/sovran /var/lib/sovran
sudo chown ec2-user:ec2-user /var/log/sovran /var/lib/sovran

sudo tee /etc/systemd/system/sovran-vllm.service >/dev/null <<EOF
[Unit]
Description=Sovran vLLM model server (Gemma 4 E2B-it)
After=network-online.target
Wants=network-online.target
# Stop retrying after 3 failures in 30m. A permanently broken engine must leave a
# readable corpse instead of restart-looping for the ASG's whole 40m grace period.
StartLimitIntervalSec=1800
StartLimitBurst=3

[Service]
Type=simple
User=ec2-user
Group=ec2-user
WorkingDirectory=/opt/sovran
Environment=CUDA_VISIBLE_DEVICES=0
Environment=HF_HUB_OFFLINE=1
Environment=TRANSFORMERS_OFFLINE=1
Environment=VLLM_DO_NOT_TRACK=1
Environment=DO_NOT_TRACK=1
Environment=VLLM_NO_USAGE_STATS=1
Environment=PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# Persist JIT / compile caches across boots (populated during AMI smoke).
Environment=TORCHINDUCTOR_CACHE_DIR=/opt/sovran/cache/torch
Environment=TRITON_CACHE_DIR=/opt/sovran/cache/triton
Environment=VLLM_CACHE_ROOT=/opt/sovran/cache/vllm
# Hydrate EBS snapshot blocks before engine load (ASG cold boot).
ExecStartPre=/opt/sovran/prewarm-model.sh ${MODEL_DIR}
# No HF token at runtime — weights are local.
ExecStart=/opt/sovran/serve.sh
Restart=on-failure
RestartSec=15
# First load can take 10–20m on cold EBS; never time out the unit start.
TimeoutStartSec=0
TimeoutStopSec=120
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- Log egress: journal -> file -> CloudWatch Logs -----------------------------
# The model subnet has no NAT but does have the Logs interface endpoint. Without this
# the only signal from a failing ASG instance is "ALB target unhealthy" 40m later.
# Prompt bodies are suppressed at the vLLM flag level above.
sudo tee /etc/systemd/system/sovran-vllm-log.service >/dev/null <<'EOF'
[Unit]
Description=Bridge sovran-vllm journal to a file for the CloudWatch agent
After=systemd-journald.service

[Service]
Type=simple
# --cursor-file resumes where the last run stopped, so reboots do not duplicate lines.
ExecStart=/bin/sh -c 'exec journalctl -f -o short-iso -u sovran-vllm --cursor-file=/var/lib/sovran/journal.cursor >> /var/log/sovran/vllm.log'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "==> installing amazon-cloudwatch-agent"
if ! sudo dnf -y install amazon-cloudwatch-agent 2>/dev/null; then
  echo "WARN: amazon-cloudwatch-agent not in repos; log egress will be file-only" >&2
fi

if [[ -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ]]; then
  sudo tee /opt/aws/amazon-cloudwatch-agent/etc/sovran-vllm.json >/dev/null <<EOF
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/sovran/vllm.log",
            "log_group_name": "${LOG_GROUP}",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "${LOG_GROUP}",
            "log_stream_name": "{instance_id}-cloud-init"
          }
        ]
      }
    }
  }
}
EOF
  sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/sovran-vllm.json
  sudo systemctl enable amazon-cloudwatch-agent
  echo "cloudwatch_agent=enabled log_group=${LOG_GROUP}" | sudo tee -a /opt/sovran/build-info.txt
else
  echo "cloudwatch_agent=missing" | sudo tee -a /opt/sovran/build-info.txt
fi

sudo systemctl daemon-reload
sudo systemctl enable sovran-vllm.service
sudo systemctl enable sovran-vllm-log.service

# Convenience health helper for operators
sudo tee /opt/sovran/healthcheck.sh >/dev/null <<'EOF'
#!/bin/bash
curl -fsS "http://127.0.0.1:8000/health" || curl -fsS "http://127.0.0.1:8000/v1/models"
EOF
sudo chmod +x /opt/sovran/healthcheck.sh

echo "==> systemd unit enabled attention=${ATTENTION_BACKEND:-<vllm-auto>} max_len=${MAX_MODEL_LEN} util=${GPU_MEM_UTIL} dtype=${DTYPE}"
