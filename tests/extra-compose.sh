#!/usr/bin/env bash
# Checks opencode-run.sh's extra-compose.yaml approval, no-new-services rule
# and cloud-mode --model rejection, with a stub `docker`.
# Run: ./tests/extra-compose.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

I="$T/instance" W="$T/project"
mkdir -p "$I/dot-gitconfig" "$I/dot-ssh" "$T/bin" "$W"
cp "$REPO"/{opencode-run.sh,llama-cpp-lib.sh,docker-compose.yaml} "$I/"
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
  run) echo "RAN ${files[*]}"; exit 0 ;;
  *) shift ;;
  esac
done
EOF
chmod +x "$T/bin/docker"

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

echo cloud >"$I/.config-mode"
out="$(PATH="$T/bin:$PATH" HOME="$T" "$I/opencode-run.sh" --model ornith15 "$W" 2>&1 </dev/null)"
check "cloud mode rejects --model" "isn't used in cloud mode" "$out"
rm "$I/.config-mode"

[[ "$(stat -c %a "$I/dot-ssh/config" 2>/dev/null)" == 600 ]] && echo "ok   ssh config written, mode 600" || { echo "FAIL ssh config missing or not 600"; fails=$((fails + 1)); }

((fails == 0)) && echo "All passed." || { echo "${fails} failed."; exit 1; }
