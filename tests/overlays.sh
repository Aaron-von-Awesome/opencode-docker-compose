#!/usr/bin/env bash
# Checks the overlay YAML parsers (read_overlay_gguf in llama-cpp-lib.sh,
# read_overlay_model_id in opencode-run.sh) against every real overlay, with
# no Docker. Run: ./tests/overlays.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
check() {
  local name="$1" want="$2" out="$3"
  if [[ "$out" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: '$out' != '$want'"
    fails=$((fails + 1))
  fi
}

# read_overlay_gguf is sourced code; $SCRIPT_DIR is all it needs set.
SCRIPT_DIR="$REPO"
source "$REPO/llama-cpp-lib.sh"

expected_gguf=(GLM-4.7-Flash-Q4_K_M.gguf Ornith-1.5-35B-Q4_K_M.gguf Qwen3.8-27B-UD-Q4_K_XL.gguf)
i=0
for f in "$REPO"/models/cpp/*.yaml; do
  check "gguf parser: $(basename "$f")" "${expected_gguf[i]}" \
    "$(read_overlay_gguf "$f")"
  i=$((i + 1))
done

# read_overlay_model_id lives in opencode-run.sh, which only executes as a
# program; pull the function out and eval it.
# shellcheck disable=SC2046
eval "$(awk '/^read_overlay_model_id\(\) \{$/,/^\}$/' "$REPO/opencode-run.sh")"
check "model id parser: ornith15 overlay" "ai/ornith-1.5:35b-a3b-q4_K_M" \
  "$(read_overlay_model_id "$REPO/models/dmr/ornith15.yaml")"

# The match must anchor on `model:` exactly, not e.g. `model_var:`. The probe
# file lives outside the repo so an interrupted run leaves nothing behind.
probe_file="$(mktemp)"
trap 'rm -f "$probe_file"' EXIT
printf 'services:\n  opencode:\n    models:\n      llm_active:\n        model_var: ACTIVE_MODEL_NAME\n' >"$probe_file"
check "model id parser ignores model_var" "" \
  "$(read_overlay_model_id "$probe_file")"

[[ "$fails" -eq 0 ]] && echo "All passed." || { echo "${fails} failed."; exit 1; }
