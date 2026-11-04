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
inspect)
  if [[ "$3" == *opencode.model* ]]; then
    # llama_start_or_reuse's state probe: "<model> <config-hash>".
    [[ -n "${INSPECT_HASH:-}" ]] && echo "ornith15 $INSPECT_HASH"
    exit 0
  fi
  [[ "$2" == "-f" && "$3" == "{{.State.Running}}" ]] && echo "${STUB_RUNNING:-true}"
  exit 0 ;;
exec)
  [[ "${STUB_EXEC_FAIL:-}" ]] && exit 1
  exit 0 ;;
compose) ;;
*) exit 0 ;;
esac
shift
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -f) files+=("$2"); shift 2 ;;
  config)
    [[ "${STUB_HASH_FAIL:-}" ]] && exit 1
    echo "llama-server stubhash"; exit 0 ;;
  up) echo "UP ${files[*]}"; exit 0 ;;
  down) echo "DOWN ${files[*]}"; exit 0 ;;
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

# A running server whose config hash matches is reused: no recreate, no down.
out="$(INSPECT_HASH=stubhash run)"
check "matching config reuses the running server" "Reusing running llama-server-standalone (ornith15)" "$out"
refute "reuse does not recreate" "UP" "$out"
refute "reuse does not remove the server" "DOWN" "$out"

# Declining the restart prompt must leave the healthy server untouched: no
# recreate and no removal (the EXIT trap fires on a failed start, never here).
out="$(INSPECT_HASH=oldhash run)"
check "declined restart aborts" "Aborted." "$out"
refute "declined restart does not recreate" "UP" "$out"
refute "declined restart keeps the server" "DOWN" "$out"

# A compose config failure (e.g. an overlay YAML typo) while a healthy server
# runs must abort WITHOUT removing that server: no restart was ever prompted.
out="$(INSPECT_HASH=stubhash STUB_HASH_FAIL=1 run)"
refute "config failure keeps the running server" "DOWN" "$out"
refute "config failure does not recreate" "UP" "$out"

# A reused server that dies during the health wait must be removed, so
# restart: unless-stopped cannot crash-loop it while nobody is watching.
out="$(INSPECT_HASH=stubhash STUB_EXEC_FAIL=1 STUB_RUNNING=false run)"
check "crashing reused server is detected" "exited. Last log lines" "$out"
check "crash-looping container is removed" "DOWN" "$out"

((fails == 0)) && echo "All passed." || { echo "${fails} failed."; exit 1; }
