#!/usr/bin/env bash
# Checks llama-cpp-run.sh's --gpu flag with a stub `docker`.
# Run: ./tests/llama-cpp-run.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

# Stub: nothing running before the start; healthy after. `compose ... up`
# prints the files it would merge.
mkdir -p "$T/bin" "$T/gguf"
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
inspect) [[ "$2" == "-f" && "$3" == "{{.State.Running}}" ]] && echo true; exit 0 ;;
exec) exit 0 ;;
compose) ;;
*) exit 0 ;;
esac
shift
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -f) files+=("$2"); shift 2 ;;
  config) echo "llama-server stubhash"; exit 0 ;;
  up) echo "UP ${files[*]}"; exit 0 ;;
  *) shift ;;
  esac
done
EOF
chmod +x "$T/bin/docker"
touch "$T/gguf/$(cd "$REPO" && source llama-cpp-lib.sh && read_overlay_gguf models/cpp/ornith15.yaml)"

run() { PATH="$T/bin:$PATH" OPENCODE_GGUF_DIR="$T/gguf" "$REPO/llama-cpp-run.sh" --model ornith15 "$@" 2>&1 </dev/null; }
check() {
  local name="$1" want="$2" out="$3"
  if grep -qF -- "$want" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$want' in:"; sed 's/^/     /' <<<"$out"
    fails=$((fails + 1))
  fi
}
refute() {
  if grep -qF -- "$2" <<<"$3"; then echo "FAIL $1: unexpected '$2'"; fails=$((fails + 1)); else echo "ok   $1"; fi
}

out="$(run)"
check "default is rocm" "UP docker-compose.llama-cpp.yaml docker-compose.llama-cpp-standalone.yaml" "$out"
refute "default has no vulkan file" "vulkan" "$out"

out="$(run --gpu vulkan)"
check "vulkan merges vulkan file" "UP docker-compose.llama-cpp.yaml docker-compose.llama-cpp.vulkan.yaml docker-compose.llama-cpp-standalone.yaml models/cpp/ornith15.yaml" "$out"

out="$(run --gpu cuda)"
check "unknown GPU is rejected" "unknown GPU 'cuda'" "$out"
refute "unknown GPU doesn't start" "UP" "$out"

out="$(run --gpu)"
check "--gpu needs a value" "--gpu requires an argument" "$out"

((fails == 0)) && echo "All passed." || { echo "${fails} failed."; exit 1; }
