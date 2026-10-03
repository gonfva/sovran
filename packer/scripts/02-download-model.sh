#!/usr/bin/env bash
# Download and pin Gemma weights onto the AMI (no runtime HF egress).
set -euo pipefail

if [[ -z "${HF_TOKEN:-}" && -z "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
  echo "ERROR: HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) must be set for model download" >&2
  exit 1
fi
export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-$HF_TOKEN}"
export HF_TOKEN="${HF_TOKEN:-$HUGGING_FACE_HUB_TOKEN}"

# shellcheck disable=SC1091
source /opt/sovran/venv/bin/activate

MODEL_ID="${MODEL_ID:-google/gemma-4-E2B-it}"
MODEL_DIR="${MODEL_DIR:-/opt/sovran/models/gemma-4-E2B-it}"
mkdir -p "$(dirname "$MODEL_DIR")"

echo "==> downloading ${MODEL_ID} -> ${MODEL_DIR}"

REV_ARGS=()
if [[ -n "${MODEL_REVISION:-}" ]]; then
  REV_ARGS=(--revision "$MODEL_REVISION")
  echo "==> pinning revision ${MODEL_REVISION}"
fi

# Prefer snapshot_download (more reliable than CLI flags across hub versions)
python - <<'PY'
import json, os
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download

model_id = os.environ.get("MODEL_ID", "google/gemma-4-E2B-it")
model_dir = os.environ.get("MODEL_DIR", "/opt/sovran/models/gemma-4-E2B-it")
rev = os.environ.get("MODEL_REVISION") or None
if rev == "":
    rev = None

print(f"snapshot_download {model_id} rev={rev} -> {model_dir}")
path = snapshot_download(
    repo_id=model_id,
    revision=rev,
    local_dir=model_dir,
    local_dir_use_symlinks=False,
)
print("downloaded to", path)

try:
    api = HfApi()
    info = api.model_info(model_id, revision=rev)
    pin = {
        "model_id": model_id,
        "sha": getattr(info, "sha", None),
        "revision_requested": rev,
        "local_dir": model_dir,
    }
except Exception as e:
    pin = {"model_id": model_id, "error": str(e), "local_dir": model_dir}

Path("/opt/sovran/model-pin.json").write_text(json.dumps(pin, indent=2) + "\n")
print("pin", pin)
PY

# Ensure no token left in shell history files for this user
rm -f /home/ec2-user/.cache/huggingface/token || true

echo "==> download-model done ($(du -sh "$MODEL_DIR" | awk '{print $1}'))"
