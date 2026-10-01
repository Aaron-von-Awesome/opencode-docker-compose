#!/usr/bin/env bash
# Initialize OpenCode on the host: copy the project artifacts from this
# cloned repo to ${HOME}/OpenCode/ (the location the `opencode` alias
# expects), then ensure that alias is installed in ~/.bashrc.
#
# Safe to re-run. Files that already exist at the destination trigger an
# overwrite prompt; the alias is added only if it isn't already present.
#
# Excluded from the copy:
#   - README.md (not part of the runtime)
#   - Anything matching `.git*` (repo metadata)
#   - This script itself
#
# Usage: ./opencode-init.sh

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
DEST="${HOME}/OpenCode"

is_excluded() {
  case "$1" in
    .git*|README.md|AGENTS.md|LICENSE|"$SCRIPT_NAME") return 0 ;;
  esac
  return 1
}

prompt_overwrite() {
  local path="$1"
  local ans
  read -r -p "  ${path} exists. Overwrite? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

copy_file() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    if ! prompt_overwrite "$dst"; then
      echo "    skipped: $dst"
      return
    fi
  fi
  cp -f "$src" "$dst"
  # Preserve executable bit if the source was executable.
  if [ -x "$src" ]; then
    chmod +x "$dst"
  fi
  echo "    copied:  $dst"
}

copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  local entry name
  for entry in "$src"/* "$src"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    if is_excluded "$name"; then
      continue
    fi
    if [ -d "$entry" ]; then
      copy_tree "$entry" "$dst/$name"
    else
      copy_file "$entry" "$dst/$name"
    fi
  done
}

echo "Initializing OpenCode -> ${DEST}"
copy_tree "$SCRIPT_DIR" "$DEST"

# Self-heal executable bits in case a previous copy lost them.
[ -f "${DEST}/opencode-run.sh" ] && chmod +x "${DEST}/opencode-run.sh"
[ -f "${DEST}/entrypoint.sh" ]   && chmod +x "${DEST}/entrypoint.sh"

# Install the `opencode` shell alias in ~/.bashrc if not already present.
BASHRC="${HOME}/.bashrc"
ALIAS_LINE='alias opencode='\''${HOME}/OpenCode/opencode-run.sh'\'

if [ ! -f "$BASHRC" ]; then
  touch "$BASHRC"
fi
if grep -Fq "alias opencode=" "$BASHRC"; then
  echo "Alias 'opencode' already present in ${BASHRC} — skipping."
else
  printf '\n# OpenCode launcher alias\n%s\n' "$ALIAS_LINE" >> "$BASHRC"
  echo "Added 'opencode' alias to ${BASHRC}."
  echo "Run 'source ~/.bashrc' or open a new shell to use it."
fi

echo "Done."
