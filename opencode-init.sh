#!/usr/bin/env bash
# Initialize OpenCode on the host: copy the project artifacts from this
# cloned repo to ${HOME}/OpenCode/ (the location the `opencode` alias
# expects), then ensure that alias is installed in ~/.bashrc.
#
# Safe to re-run. Files that already exist at the destination trigger an
# overwrite prompt; the alias is added only if it isn't already present.
#
# After copying, prompts the user to choose a configuration mode
# ("cloud" for third-party providers, "local" for Docker Model Runner)
# and deploys the matching template as opencode.jsonc.template. The
# choice is saved to ${DEST}/.config-mode so re-runs skip the prompt.
#
# Excluded from the copy:
#   - README.md (not part of the runtime)
#   - Anything matching `.git*` (repo metadata)
#   - This script itself
#   - opencode.jsonc.cloud.template and opencode.jsonc.local.template
#     (handled separately by select_config_mode)
#
# Usage: ./opencode-init.sh

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
DEST="${HOME}/OpenCode"

is_excluded() {
  case "$1" in
    .git*|README.md|AGENTS.md|LICENSE|"$SCRIPT_NAME"|opencode.jsonc.cloud.template|opencode.jsonc.local.template) return 0 ;;
  esac
  return 1
}

# Prompt the user to choose a configuration mode (cloud or local) and
# deploy the matching template as opencode.jsonc.template at the destination.
# Remembers the choice in ${DEST}/.config-mode so re-runs skip the prompt.
CONFIG_MODE_FILE="${DEST}/.config-mode"

select_config_mode() {
  local saved_mode=""
  if [ -f "$CONFIG_MODE_FILE" ]; then
    saved_mode="$(cat "$CONFIG_MODE_FILE")"
    echo "Saved config mode: ${saved_mode} (from ${CONFIG_MODE_FILE})"
    echo "Delete this file and re-run to change it."
    echo "$saved_mode"
    return
  fi

  local ans
  while true; do
    read -r -p "Configuration type — [c] Cloud (third-party provider) or [l] Local (Docker Model Runner): " ans
    case "$ans" in
      c|C|cloud|CLOUD)
        echo "cloud"
        return
        ;;
      l|L|local|LOCAL)
        echo "local"
        return
        ;;
      *)
        echo "Please enter 'c' for cloud or 'l' for local."
        ;;
    esac
  done
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

# Deploy the selected configuration template. Both source templates were
# excluded from the tree copy above; we copy only the chosen one as
# opencode.jsonc.template, which opencode-run.sh will move into
# dot-config/opencode/ on launch.
MODE="$(select_config_mode)"
case "$MODE" in
  cloud)
    cp -f "${SCRIPT_DIR}/opencode.jsonc.cloud.template" "${DEST}/opencode.jsonc.template"
    echo "Deployed cloud config -> ${DEST}/opencode.jsonc.template"
    ;;
  local)
    cp -f "${SCRIPT_DIR}/opencode.jsonc.local.template" "${DEST}/opencode.jsonc.template"
    echo "Deployed local config -> ${DEST}/opencode.jsonc.template"
    ;;
  *)
    echo "Error: unknown config mode '${MODE}'" >&2
    exit 1
    ;;
esac
printf '%s\n' "$MODE" > "$CONFIG_MODE_FILE"

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
