#!/usr/bin/env bash
# Install vLLM into a dedicated venv on Amazon Deep Learning AMI (AL2023 + NVIDIA).
# Base image must be Amazon DLAMI — never an older Sovran AMI.
set -euo pipefail

echo "==> install-vllm: system packages"
sudo dnf -y update || true
# AL2023 ships curl-minimal; do NOT install curl (conflicts with curl-minimal).
# ninja-build: FlashInfer / Triton JIT-compiles kernels on first warmup.
# gcc-c++/make: same JIT path needs a C++ toolchain on minimal AL2023 images.
# Install packages individually so one missing/conflicting pkg does not abort python3.11.
for pkg in python3.11 python3.11-pip python3.11-devel git gcc gcc-c++ make ninja-build fio; do
  sudo dnf -y install "$pkg" 2>/dev/null || sudo yum -y install "$pkg" 2>/dev/null || \
    echo "WARN: could not install $pkg (may already be present)"
done

# vLLM needs Python >=3.10, and the DLAMI's default python3 is 3.9. Prefer 3.12: it is
# already on the image, so this does not depend on a dnf install succeeding. Never 3.9.
PYTHON=""
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then
    PYTHON="$cand"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "ERROR: need Python >=3.10 for vLLM (python3.11 preferred). Found: $(python3 --version 2>&1)" >&2
  exit 1
fi
PY_MAJOR_MINOR=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  :
else
  echo "ERROR: $PYTHON is $PY_MAJOR_MINOR; vLLM needs >=3.10" >&2
  exit 1
fi

echo "==> using $PYTHON ($($PYTHON --version))"
sudo mkdir -p /opt/sovran /opt/sovran/cache/{torch,triton,vllm}
sudo chown -R ec2-user:ec2-user /opt/sovran

"$PYTHON" -m venv /opt/sovran/venv
# shellcheck disable=SC1091
source /opt/sovran/venv/bin/activate

# Assert on the *venv* interpreter, not on whichever binary `command -v` found.
# The venv is what runs vLLM, and a stale/lower interpreter here is the kind of
# mismatch that gets misdiagnosed as a library bug (see flashinfer note below).
VENV_PY_VER=$(python -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
python -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || {
  echo "ERROR: venv interpreter is ${VENV_PY_VER}; vLLM needs >=3.10" >&2
  exit 1
}
echo "==> venv interpreter: $(python -VV)"

pip install --upgrade pip wheel setuptools

# Install source. Upstream's Gemma 4 recipe ships the model on a pre-release wheel:
#   https://docs.vllm.ai/projects/recipes/en/stable/Google/Gemma4.html
# VLLM_PRE_RELEASE=true  -> nightly index, VLLM_VERSION optional (empty = latest nightly)
# VLLM_PRE_RELEASE=false -> released wheel, VLLM_VERSION required
VLLM_PRE_RELEASE="${VLLM_PRE_RELEASE:-true}"
VLLM_INDEX_URL="${VLLM_INDEX_URL:-https://wheels.vllm.ai/nightly}"

if [[ "$VLLM_PRE_RELEASE" == "true" ]]; then
  VLLM_SPEC="vllm${VLLM_VERSION:+==${VLLM_VERSION}}"
  echo "==> pip install --pre ${VLLM_SPEC} (index ${VLLM_INDEX_URL})"
  pip install --pre "$VLLM_SPEC" --extra-index-url "$VLLM_INDEX_URL"
else
  if [[ -z "${VLLM_VERSION:-}" ]]; then
    echo "ERROR: VLLM_PRE_RELEASE=false requires an explicit VLLM_VERSION" >&2
    exit 1
  fi
  echo "==> pip install vllm==${VLLM_VERSION} (released wheel)"
  pip install "vllm==${VLLM_VERSION}"
fi
pip install huggingface_hub

VLLM_RESOLVED=$(python -c "import vllm; print(vllm.__version__)")
echo "==> resolved vllm ${VLLM_RESOLVED}"

# Optional pin only when TRANSFORMERS_VERSION is set (vLLM 0.26+ needs transformers>=5.5.3).
if [[ -n "${TRANSFORMERS_VERSION:-}" ]]; then
  echo "==> pip install transformers==${TRANSFORMERS_VERSION} (explicit pin)"
  pip install "transformers==${TRANSFORMERS_VERSION}"
fi

# flashinfer import gate.
#
# flashinfer is load-bearing at runtime: on 0.27.1 / A10G, vLLM serves Gemma 4's seven
# full-attention layers (head_dim 512) with the FLASHINFER backend. So a broken import
# must stop the bake, not be worked around.
#
# History: a previous bake unconditionally rewrote every flashinfer source file
# containing `array.array[`, blaming Py3.11. Measured on the DLAMI (AL2023 2026-08-03):
# `array.array[int]` raises on its default python3 = **3.9.25** and works on 3.12. The
# image ships 3.9 and 3.12 but no 3.11, so the old
#   PYTHON=python3.11; command -v "$PYTHON" || PYTHON=python3
# fallback quietly built the venv on 3.9 whenever the python3.11 dnf install failed.
# The interpreter was the bug; the library was fine. Verified 2026-08-12 on a 3.12
# venv: imports clean, no patching. Fail loudly here rather than editing site-packages.
python - <<'PY'
import sys, traceback

try:
    import flashinfer.comm  # noqa: F401
except ImportError:
    print("flashinfer not installed by this vLLM build — skipping gate")
    raise SystemExit(0)
except Exception:
    print("ERROR: flashinfer.comm failed to import on", sys.version, file=sys.stderr)
    traceback.print_exc()
    print(
        "\nIf this is \"type 'array.array' is not subscriptable\", the venv is on an\n"
        "interpreter older than 3.10 — fix the interpreter, do not patch flashinfer.",
        file=sys.stderr,
    )
    raise SystemExit(1)
print("flashinfer.comm import ok")
PY

# Gemma4 tool chat template (vLLM examples — not shipped inside the wheel).
# Bake needs internet; runtime is offline, so this file must land on the AMI.
# Released wheel -> matching tag; nightly -> main.
echo "==> installing tool_chat_template_gemma4.jinja"
TEMPLATE_URL_BASE="https://raw.githubusercontent.com/vllm-project/vllm"
TEMPLATE_REFS=("main")
if [[ "$VLLM_PRE_RELEASE" != "true" ]]; then
  TEMPLATE_REFS=("v${VLLM_VERSION}" "main")
fi
template_ok=0
for ref in "${TEMPLATE_REFS[@]}"; do
  if curl -fsSL "${TEMPLATE_URL_BASE}/${ref}/examples/tool_chat_template_gemma4.jinja" \
    -o /opt/sovran/tool_chat_template_gemma4.jinja; then
    echo "==> chat template from ref ${ref}"
    template_ok=1
    break
  fi
done
if [[ "$template_ok" -ne 1 ]]; then
  # Without it the gemma4 tool-call path is wrong, and the failure would only show up
  # later as an agent that never gets a tool call back. Fail here instead.
  echo "ERROR: could not fetch tool_chat_template_gemma4.jinja from any ref" >&2
  exit 1
fi

# Exact resolved dependency set — the AMI is the artifact, but this makes the venv
# reproducible and diffable between bakes.
pip freeze | sudo tee /opt/sovran/requirements.lock.txt >/dev/null

# Record versions for operators
{
  echo "vllm_requested=${VLLM_VERSION:-<latest>}"
  echo "vllm_pre_release=${VLLM_PRE_RELEASE}"
  echo "vllm_index_url=${VLLM_INDEX_URL}"
  echo "vllm_resolved=${VLLM_RESOLVED}"
  echo "transformers_version_pin=${TRANSFORMERS_VERSION:-<vllm-resolved>}"
  echo "venv_python=${VENV_PY_VER}"
  python -c "import transformers; print('transformers_import', transformers.__version__)" || true
  python -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda)" || true
  nvidia-smi || true
  echo "base_image=amazon-dlami-expected"
} | sudo tee /opt/sovran/build-info.txt

echo "==> install-vllm done"
