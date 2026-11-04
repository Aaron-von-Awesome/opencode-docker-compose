#!/usr/bin/env bash
# Checks opencode-run.sh's extra-compose.yaml approval, no-new-services rule,
# cloud-mode --model rejection and COMPOSE_IGNORE_ORPHANS per backend, with
# stub `docker` and `curl`.
# Run: ./tests/extra-compose.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

I="$T/instance" W="$T/project"
mkdir -p "$I/dot-gitconfig" "$I/dot-ssh" "$T/bin" "$W"
cp "$REPO"/{opencode-run.sh,llama-cpp-lib.sh,docker-compose.yaml,docker-compose.llama-cpp.yaml,docker-compose.llama-cpp.vulkan.yaml} "$I/"
cp -r "$REPO/models" "$I/"
touch "$I/dot-gitconfig/.gitconfig" "$I/dot-ssh/id_opencode"

# Stub: `compose ... config --services` lists the -f files' services;
# plain `config` echoes the files as "resolved" output with a name: line;
# `compose ... run` prints the files it would merge.
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == compose ]] || exit 0
shift
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -f) files+=("$2"); shift 2 ;;
  config)
    [[ "${2:-}" == --services ]] || { echo "name: stub"; echo "# resolved"; cat "${files[@]}"; exit; }
    awk '/^services:/ {s=1; next} /^[^ ]/ {s=0} s && /^  [a-z]/ {sub(/:.*/, ""); sub(/^ +/, ""); print}' "${files[@]}" | sort -u; exit ;;
  run) echo "RAN ${files[*]} IGNORE_ORPHANS=${COMPOSE_IGNORE_ORPHANS:-}"; exit 0 ;;
  *) shift ;;
  esac
done
EOF
chmod +x "$T/bin/docker"
# Stub: a remote llama-server reporting one model and accepting no-key requests.
cat >"$T/bin/curl" <<'EOF2'
#!/usr/bin/env bash
[[ "${*: -1}" == */models ]] && echo '{"data":[{"id":"stub-model"}]}' || echo 404
EOF2
chmod +x "$T/bin/curl"

# umask 002 (Ubuntu user-private-group default) so the ssh config mode check bites.
run() { (umask 002; PATH="$T/bin:$PATH" HOME="$T" "$I/opencode-run.sh" "$W" 2>&1); }
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

out="$(run </dev/null)"
check "no extra file runs" "RAN docker-compose.yaml" "$out"
refute "no extra file merges nothing" "approved" "$out"

printf 'services:\n  opencode:\n    privileged: true\n' >"$W/extra-compose.yaml"
out="$(echo n | run)"
check "new file asks" "New or changed" "$out"
refute "declined file doesn't run" "RAN" "$out"

out="$(echo y | run)"
check "approved file is merged from the instance dir" "$I/.approved-extra-compose/" "$out"
check "approved file runs" "RAN" "$out"

out="$(run </dev/null)"
check "same file isn't asked again" "RAN" "$out"
refute "same file has no prompt" "New or changed" "$out"

printf 'services:\n  opencode:\n    privileged: false\n' >"$W/extra-compose.yaml"
out="$(run </dev/null)"
check "changed file asks again" "New or changed" "$out"
refute "changed file without OK doesn't run" "RAN" "$out"

printf 'services:\n  opencode:\n    privileged: false\n    \033[1A\033[2K\n' >"$W/extra-compose.yaml"
out="$(echo n | run)"
check "control codes are shown, not run" "^[[1A^[[2K" "$out"

printf 'services:\n  opencode:\n    privileged: false\n    tty: true\n' >"$W/extra-compose.yaml"
out="$(echo y | run)"
approved="$(grep -o "$I/.approved-extra-compose/[0-9a-f]*\.yaml" <<<"$out" | head -1)"
check "approves compose's resolved output" "# resolved" "$(cat "$approved" 2>/dev/null)"
refute "resolved output drops name:" "name:" "$(cat "$approved" 2>/dev/null)"

printf 'services:\n  kiwifs:\n    image: x\n' >"$W/extra-compose.yaml"
out="$(echo y | run)"
check "new service is rejected" "adds service(s): kiwifs" "$out"
refute "new service doesn't run" "RAN" "$out"

rm "$W/extra-compose.yaml"
echo cloud >"$I/.config-mode"
out="$(PATH="$T/bin:$PATH" HOME="$T" "$I/opencode-run.sh" --model ornith15 "$W" 2>&1 </dev/null)"
check "cloud mode rejects --model" "isn't used in cloud mode" "$out"
check "cloud launch ignores orphans" "IGNORE_ORPHANS=true" "$(run </dev/null)"
rm "$I/.config-mode"

echo local >"$I/.config-mode"
echo remote >"$I/.local-backend"
echo "http://host.docker.internal:8080/v1" >"$I/.remote-llama-url"
check "remote launch ignores orphans" "IGNORE_ORPHANS=true" "$(run </dev/null)"

echo cpp >"$I/.local-backend"
mkdir -p "$T/gguf"
touch "$T/gguf/$(cd "$REPO" && source llama-cpp-lib.sh && read_overlay_gguf models/cpp/ornith15.yaml)"
out="$(umask 002; PATH="$T/bin:$PATH" HOME="$T" OPENCODE_GGUF_DIR="$T/gguf" "$I/opencode-run.sh" --model ornith15 "$W" 2>&1 </dev/null)"
check "cpp launch runs" "RAN docker-compose.yaml docker-compose.llama-cpp.yaml" "$out"
refute "cpp launch keeps orphan warnings" "IGNORE_ORPHANS=true" "$out"
refute "rocm launch has no vulkan file" "vulkan" "$out"
cpp_run() { (umask 002; PATH="$T/bin:$PATH" HOME="$T" OPENCODE_GGUF_DIR="$T/gguf" "$I/opencode-run.sh" --model ornith15 "$W" 2>&1 </dev/null); }
echo vulkan >"$I/.llama-gpu"
check "vulkan launch merges vulkan file" "RAN docker-compose.yaml docker-compose.llama-cpp.yaml docker-compose.llama-cpp.vulkan.yaml models/cpp/ornith15.yaml" "$(cpp_run)"
echo cuda >"$I/.llama-gpu"
out="$(cpp_run)"
check "unknown GPU is rejected" "unknown GPU 'cuda'" "$out"
refute "unknown GPU doesn't run" "RAN" "$out"
rm "$I/.config-mode" "$I/.local-backend" "$I/.remote-llama-url" "$I/.llama-gpu"

[[ "$(stat -c %a "$I/dot-ssh/config" 2>/dev/null)" == 600 ]] && echo "ok   ssh config written, mode 600" || { echo "FAIL ssh config missing or not 600"; fails=$((fails + 1)); }

((fails == 0)) && echo "All passed." || { echo "${fails} failed."; exit 1; }
