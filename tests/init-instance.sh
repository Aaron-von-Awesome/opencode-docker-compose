#!/usr/bin/env bash
# Checks opencode-init.sh's instance-directory and alias rules in a throwaway
# HOME. Run: ./tests/init-instance.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

# Usage: run ANSWER... — pipes one answer per line (then "n" forever) into init.
run() {
  { printf '%s\n' "$@"; yes n; } | HOME="$T" "$REPO/opencode-init.sh" 2>&1
}
check() {
  local name="$1" want="$2" out="$3"
  if grep -qF -- "$want" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$want' in:"; sed 's/^/     /' <<<"$out"
    fails=$((fails + 1))
  fi
}

out="$(run OpenCode-Llama c)"
check "relative name goes under HOME" "alias opencode-llama='${T}/OpenCode-Llama/opencode-run.sh'" "$(cat "$T/.bashrc")"
[[ -d "$T/OpenCode-Llama" ]] || { echo "FAIL instance dir not created"; fails=$((fails + 1)); }

out="$(run OpenCode-Llama)"
check "re-run same instance" "already present" "$out"
check "re-run adds no second alias" "1" "$(grep -c 'alias opencode-llama=' "$T/.bashrc")"

mkdir -p "$T/x"
out="$(run "~/x/opencode-llama")"
check "alias for another instance" "launches a different instance" "$out"

out="$(run "$REPO/sub")"
check "directory inside the repo" "is inside this repo" "$out"
[[ ! -e "$REPO/sub" ]] || { echo "FAIL created $REPO/sub"; fails=$((fails + 1)); }

out="$(run "~/Bash")"
check "name that hides a command" "is already a command" "$out"

out="$(run "~/bad name")"
check "name that can't be an alias" "can't be an alias name" "$out"

sed -i 's/^alias opencode-llama=/# &/' "$T/.bashrc"
out="$(run OpenCode-Llama)"
check "commented alias, same instance" "is commented out" "$out"
out="$(run "~/x/opencode-llama")"
check "commented alias, other instance" "commented-out 'opencode-llama' alias" "$out"

printf "alias opencode='\${HOME}/OpenCode/opencode-run.sh'\n" >>"$T/.bashrc"
out="$(run "" c)"
check "legacy \${HOME} alias counts as this instance" "Alias 'opencode' already present" "$out"

((fails == 0)) && echo "All passed." || { echo "${fails} failed."; exit 1; }
