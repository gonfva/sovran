#!/usr/bin/env bash
# Start vLLM once during bake to fail fast if the stack is broken.
# Also warms Triton/torch compile caches that ship with the AMI.
set -euo pipefail

if [[ "${SKIP_GPU_SMOKE:-false}" == "true" ]]; then
  echo "==> smoke: SKIP_GPU_SMOKE=true — not starting vLLM."
  echo "==> THIS AMI IS UNVALIDATED: it has never served a token. Do not wire it into"
  echo "==> infra/envs/reference/terraform.tfvars. The AMI name carries -unvalidated-."
  echo "validated=false" | sudo tee -a /opt/sovran/build-info.txt
  echo "skip_gpu_smoke=explicit" | sudo tee -a /opt/sovran/build-info.txt
  exit 0
fi

# Hard failure, not a silent pass. A no-GPU builder used to exit 0 here, which is how
# ami-03ce9a122f75e2cc0 (2026-08-10, 18 min bake) was produced and tagged as if it worked.
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: no usable GPU on this builder and SKIP_GPU_SMOKE is not set." >&2
  echo "       Build on a GPU instance (g6.xlarge in eu-west-2, g5.xlarge in eu-west-1), or pass" >&2
  echo "       -var skip_gpu_smoke=true to knowingly produce an UNVALIDATED AMI." >&2
  echo "validated=false" | sudo tee -a /opt/sovran/build-info.txt
  exit 1
fi

# shellcheck disable=SC1091
source /opt/sovran/venv/bin/activate

echo "==> smoke: GPU"
nvidia-smi || true

echo "==> smoke: pre-warm model files (also exercises EBS path)"
/opt/sovran/prewarm-model.sh /opt/sovran/models/gemma-4-E2B-it || true

echo "==> smoke: starting vLLM temporarily"
sudo systemctl start sovran-vllm.service

# 50 min, not 25: the 2026-08-12 bake spent 1354 s just loading weights (cold 4KB mmap
# reads against an unprovisioned gp3) and missed a 25 min budget by ~1 min, failing a
# build whose AMI was actually fine. The builder volume now provisions 12000 IOPS, but
# keep generous headroom — a timeout here throws away a ~40 min build.
echo "==> smoke: following journal + waiting for /health (up to 50 min for first load)"
ok=0
START_TS=$(date +%s)
for i in $(seq 1 300); do
  if curl -fsS --max-time 5 http://127.0.0.1:8000/health >/dev/null 2>&1 \
    || curl -fsS --max-time 5 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
    ok=1
    break
  fi
  # Primary signal: unit journal (not silent health retries)
  if (( i % 3 == 0 )); then
    ELAPSED=$(( $(date +%s) - START_TS ))
    echo "--- journal (attempt $i, ${ELAPSED}s) ---"
    sudo journalctl -u sovran-vllm -n 30 --no-pager || true
  fi
  # Fail fast if unit died and systemd gave up (Restart=on-failure may still be cycling)
  if ! systemctl is-active --quiet sovran-vllm; then
    echo "WARN: sovran-vllm not active; dumping journal" >&2
    sudo journalctl -u sovran-vllm -n 80 --no-pager || true
  fi
  sleep 10
done

if [[ "$ok" -ne 1 ]]; then
  echo "ERROR: vLLM did not become healthy during AMI bake — full journal:" >&2
  sudo journalctl -u sovran-vllm -n 200 --no-pager || true
  exit 1
fi

ELAPSED=$(( $(date +%s) - START_TS ))
echo "==> smoke: healthy after ${ELAPSED}s"
echo "smoke_ready_seconds=${ELAPSED}" | sudo tee -a /opt/sovran/build-info.txt

echo "==> smoke: chat completion"
SMOKE_MODEL=$(curl -fsS http://127.0.0.1:8000/v1/models | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])')
echo "using model id: $SMOKE_MODEL"
curl -fsS --max-time 180 http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${SMOKE_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in one word.\"}],\"max_tokens\":256}" \
  | head -c 500
echo
# max_tokens must leave room for thinking: Gemma 4 with --reasoning-parser gemma4 spent
# all 16 tokens of the old budget reasoning and returned finish_reason=length with no
# answer, which still looked like a pass.

# The agent (images/agent/loop.py) drives this model through tool calls, so a bake that
# only proves /v1/chat/completions proves half of what Phase 4 needs. Exercise the
# gemma4 tool-call parser + chat template here, where the failure is cheap to see.
echo "==> smoke: tool call (gemma4 parser + chat template)"
TOOL_REQ=$(python3 - "$SMOKE_MODEL" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "max_tokens": 128,
    "messages": [{"role": "user", "content": "What is the weather in Dublin? Use the tool."}],
    "tools": [{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city.",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string", "description": "City name"}},
                "required": ["city"],
            },
        },
    }],
    "tool_choice": "auto",
}))
PY
)
TOOL_RESP=$(curl -fsS --max-time 180 http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' -d "$TOOL_REQ")
if python3 -c '
import json, sys
msg = json.loads(sys.stdin.read())["choices"][0]["message"]
calls = msg.get("tool_calls") or []
print("tool_calls:", json.dumps(calls)[:300])
sys.exit(0 if calls else 1)
' <<<"$TOOL_RESP"; then
  echo "tool_call_smoke=pass" | sudo tee -a /opt/sovran/build-info.txt
else
  echo "ERROR: model returned no parsed tool_calls — tool-call parser or chat template is wrong." >&2
  echo "Response was:" >&2
  echo "$TOOL_RESP" | head -c 1000 >&2
  echo "tool_call_smoke=fail" | sudo tee -a /opt/sovran/build-info.txt
  exit 1
fi

# Keep compile caches owned by service user
sudo chown -R ec2-user:ec2-user /opt/sovran/cache || true
du -sh /opt/sovran/cache/* 2>/dev/null || true

echo "==> smoke: stop service before AMI snapshot (starts on next boot)"
sudo systemctl stop sovran-vllm.service

# Only reached when the engine served both a completion and a parsed tool call.
echo "validated=true" | sudo tee -a /opt/sovran/build-info.txt

echo "==> smoke-local done"
