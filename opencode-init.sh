#!/usr/bin/env bash
# Usage: ./opencode-init.sh
# Copies this repo to ${HOME}/OpenCode/ (prompting before overwrites), then:
#   - asks cloud or local and deploys the matching opencode.jsonc.*.template
#     as opencode.jsonc.template (saved to .config-mode)
#   - local only: asks llama.cpp (cpp) or Docker Model Runner (dmr)
#     (saved to .local-backend)
#   - adds the `opencode` alias to ~/.bashrc if missing
# Saved choices skip their prompts on re-run; delete the file to re-prompt.
# Not copied: .git*, README.md, AGENTS.md, LICENSE, this script, and the two
# opencode.jsonc.*.template files.

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

# Prints "cloud" or "local": the saved .config-mode, else prompts. Messages go
# to stderr because the caller captures stdout.
CONFIG_MODE_FILE="${DEST}/.config-mode"

select_config_mode() {
  local saved_mode=""
  if [ -f "$CONFIG_MODE_FILE" ]; then
    saved_mode="$(cat "$CONFIG_MODE_FILE")"
    echo "Saved config mode: ${saved_mode} (from ${CONFIG_MODE_FILE})" >&2
    echo "Delete this file and re-run to change it." >&2
    echo "$saved_mode"
    return
  fi

  local ans
  while true; do
    read -r -p "Configuration type — [c] Cloud (third-party provider) or [l] Local (llama.cpp or Docker Model Runner): " ans
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
        echo "Please enter 'c' for cloud or 'l' for local." >&2
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

# Deploy the chosen template; opencode-run.sh moves it into dot-config/ on launch.
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

# Local mode only: opencode-run.sh reads this to pick models/<backend>/.
BACKEND_FILE="${DEST}/.local-backend"
if [ "$MODE" = "local" ]; then
  if [ -f "$BACKEND_FILE" ]; then
    echo "Saved local backend: $(cat "$BACKEND_FILE") (from ${BACKEND_FILE})"
    echo "Delete this file and re-run to change it."
  else
    while true; do
      read -r -p "Local backend — [c] llama.cpp (default) or [d] Docker Model Runner: " ans
      case "$ans" in
        ""|c|C) BACKEND="cpp"; break ;;
        d|D) BACKEND="dmr"; break ;;
        *) echo "Please enter 'c' for llama.cpp or 'd' for Docker Model Runner." ;;
      esac
    done
    printf '%s\n' "$BACKEND" > "$BACKEND_FILE"
    echo "Saved local backend: ${BACKEND} -> ${BACKEND_FILE}"
  fi
fi

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
