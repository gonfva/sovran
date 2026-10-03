#!/usr/bin/env bash
# Patch vLLM Gemma4 for transformers>=5 heterogeneous head_dim — *when needed*.
#
# Background:
#   Gemma4 dual attention: sliding head_dim=256, full global_head_dim=512 (E2B).
#   Released vLLM 0.26.x / 0.27.x still do:
#     getattr(config, "global_head_dim", config.head_dim)
#   for full layers. That works when HF config still exposes global_head_dim
#   (current google/gemma-4-E2B-it does). It fails when transformers folds
#   the attribute into per_layer_config[i].head_dim and:
#     - raises AmbiguousGlobalPerLayerAttributeError, or
#     - falls back to head_dim=256 → weight load size [512] into [256].
#
#   Upstream *main* already uses gemma4_layer_config() / per-layer convertor
#   and needs no patch. Released wheels through 0.27.1 still need this.
#
# Safe to re-run: idempotent marker. Skips cleanly if upstream already fixed.
set -euo pipefail

VENV_PY="${VENV_PY:-/opt/sovran/venv/bin/python}"
SITE=$("$VENV_PY" -c "import vllm, pathlib; print(pathlib.Path(vllm.__file__).resolve().parent)")
VLLM_VER=$("$VENV_PY" -c "import vllm; print(getattr(vllm, '__version__', 'unknown'))")

CONV="$SITE/transformers_utils/model_arch_config_convertor.py"
G4="$SITE/model_executor/models/gemma4.py"

echo "==> patch-gemma4-head-dim: vllm=${VLLM_VER} site=${SITE}"

if [[ ! -f "$G4" ]]; then
  echo "ERROR: missing gemma4 model: $G4" >&2
  exit 1
fi

# Upstream main already resolved via gemma4_layer_config — leave alone.
if grep -q "gemma4_layer_config" "$G4"; then
  echo "==> upstream already uses gemma4_layer_config — no patch needed"
  echo "gemma4_head_dim_patch=skipped-upstream-fixed" | sudo tee -a /opt/sovran/build-info.txt
  exit 0
fi

if [[ ! -f "$CONV" ]]; then
  echo "ERROR: missing convertor: $CONV" >&2
  exit 1
fi

"$VENV_PY" - <<PY
from pathlib import Path
import ast
import re

conv = Path("$CONV")
g4 = Path("$G4")
MARKER = "sovran-gemma4-heterogeneous-head-dim-v2"

def backup(p: Path) -> None:
    bak = p.with_suffix(p.suffix + ".bak-gemma4")
    if not bak.exists():
        bak.write_text(p.read_text())

# --- 1) get_head_size: max over per-layer head_dim, else head/global ---
backup(conv)
ctext = conv.read_text()
m = re.search(
    r"class Gemma4ModelArchConfigConvertor\(ModelArchConfigConvertorBase\):",
    ctext,
)
if not m:
    raise SystemExit("Gemma4ModelArchConfigConvertor not found — check vLLM version")
start = m.start()
rest = ctext[start:]
next_cls = re.search(r"\nclass \w+", rest[1:])
end = start + 1 + next_cls.start() if next_cls else len(ctext)
block = ctext[start:end]
if MARKER in block and "per_layer_config" in block:
    print("convertor already at", MARKER)
else:
    meth_pat = re.compile(
        r"    def get_head_size\(self\) -> int:\n(?:        .*\n)+",
    )
    new_get = f'''    def get_head_size(self) -> int:
        # {MARKER}
        # transformers>=5 may fold global_head_dim into per_layer_config[i].head_dim
        cfg = self.hf_text_config
        try:
            object.__setattr__(cfg, "allow_global_per_layer_attribute_access", True)
        except Exception:
            pass
        dims = []
        plc = getattr(cfg, "per_layer_config", None)
        if plc is not None:
            try:
                for i in range(len(plc)):
                    hd = getattr(plc[i], "head_dim", None)
                    if hd is not None:
                        dims.append(int(hd))
            except Exception:
                pass
        if dims:
            return max(dims)

        def _safe(name, default=0):
            try:
                v = getattr(cfg, name, default)
                return default if v is None else v
            except Exception:
                d = object.__getattribute__(cfg, "__dict__")
                if name in d and d[name] is not None:
                    return d[name]
                return default

        head_dim = int(_safe("head_dim", 0) or 0)
        global_head_dim = int(_safe("global_head_dim", 0) or 0)
        return max(head_dim, global_head_dim) or super().get_head_size()

'''
    if not meth_pat.search(block):
        # Some versions only have is_mm_prefix_lm; inject get_head_size before next class
        inject = re.sub(
            r"(class Gemma4ModelArchConfigConvertor\(ModelArchConfigConvertorBase\):.*?)(?=\nclass |\Z)",
            r"\1\n" + new_get,
            block,
            count=1,
            flags=re.S,
        )
        if inject == block:
            raise SystemExit("get_head_size not found and inject failed in Gemma4 convertor")
        new_block = inject
    else:
        new_block = meth_pat.sub(new_get, block, count=1)
    ctext = ctext[:start] + new_block + ctext[end:]
    ast.parse(ctext)
    conv.write_text(ctext)
    print("convertor get_head_size patched")

# --- 2) gemma4.py: use per-layer head_dim for decoder layers ---
backup(g4)
gtext = g4.read_text()
old_sel = '''        # Gemma4 uses different head dimensions for sliding vs full attention
        layer_type = config.layer_types[layer_idx]
        self.is_full_attention = layer_type == "full_attention"
        if self.is_full_attention:
            head_dim = getattr(config, "global_head_dim", config.head_dim)
        else:
            head_dim = config.head_dim
'''
new_sel = f'''        # Gemma4 uses different head dimensions for sliding vs full attention
        # {MARKER}
        layer_type = config.layer_types[layer_idx]
        self.is_full_attention = layer_type == "full_attention"
        # Prefer per_layer_config[i].head_dim (sliding=256, full=512 on E2B).
        head_dim = None
        plc = getattr(config, "per_layer_config", None)
        if plc is not None:
            try:
                head_dim = plc[layer_idx].head_dim
            except Exception:
                head_dim = None
        if head_dim is None:
            try:
                object.__setattr__(
                    config, "allow_global_per_layer_attribute_access", True
                )
            except Exception:
                pass
            if self.is_full_attention:
                head_dim = getattr(config, "global_head_dim", None)
                if head_dim is None:
                    head_dim = getattr(config, "head_dim", None)
            else:
                head_dim = getattr(config, "head_dim", None)
        if head_dim is None:
            raise RuntimeError(
                f"Gemma4 layer {{layer_idx}}: could not resolve head_dim "
                f"(full={{self.is_full_attention}})"
            )
'''
if MARKER in gtext and "per_layer_config" in gtext and "head_dim = plc[layer_idx]" in gtext:
    print("gemma4.py already at", MARKER)
elif old_sel in gtext:
    gtext = gtext.replace(old_sel, new_sel, 1)
    ast.parse(gtext)
    g4.write_text(gtext)
    print("gemma4.py layer head_dim selection patched")
else:
    loose = re.compile(
        r"        # Gemma4 uses different head dimensions for sliding vs full attention\n"
        r"        layer_type = config\.layer_types\[layer_idx\]\n"
        r"        self\.is_full_attention = layer_type == \"full_attention\"\n"
        r"        if self\.is_full_attention:\n"
        r"            head_dim = getattr\(config, \"global_head_dim\", config\.head_dim\)\n"
        r"        else:\n"
        r"            head_dim = config\.head_dim\n",
    )
    if loose.search(gtext):
        gtext = loose.sub(new_sel, gtext, count=1)
        ast.parse(gtext)
        g4.write_text(gtext)
        print("gemma4.py layer head_dim selection patched (loose)")
    else:
        raise SystemExit(
            "gemma4.py head_dim selection pattern not found — check vLLM version"
        )

print("ok")
PY

echo "gemma4_head_dim_patch=applied-v2" | sudo tee -a /opt/sovran/build-info.txt
echo "==> patch-gemma4-head-dim done"
