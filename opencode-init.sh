#!/usr/bin/env bash
# Usage: ./opencode-init.sh
# Asks for an instance directory (default ${HOME}/OpenCode) and copies this
# repo there (prompting before overwrites), then:
#   - asks cloud or local and deploys the matching opencode.jsonc.*.template
#     as opencode.jsonc.template (saved to .config-mode)
#   - local only: asks llama.cpp (cpp), Docker Model Runner (dmr), or a
#     remote llama.cpp server (remote) (saved to .local-backend); remote also
#     asks for the server URL and optional API key (.remote-llama-url/-key)
#   - adds an alias named after the lowercased directory (~/OpenCode ->
#     `opencode`, ~/OpenCode-llama -> `opencode-llama`) to ~/.bashrc if missing
# Each directory is a separate instance with its own config and state.
# Saved choices skip their prompts on re-run; delete the file to re-prompt.
# Not copied: .git*, README.md, AGENTS.md, LICENSE, tests/, this script, and the two
# opencode.jsonc.*.template files.

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
read -r -p "Instance directory [${HOME}/OpenCode]: " DEST
DEST="${DEST:-${HOME}/OpenCode}"
DEST="${DEST/#\~/${HOME}}"
[[ "$DEST" = /* ]] || DEST="${HOME}/${DEST}"
DEST="${DEST%/}"
if [[ "$DEST/" == "$SCRIPT_DIR/"* ]]; then
  echo "Error: ${DEST} is inside this repo (${SCRIPT_DIR}); pick a directory outside it." >&2
  exit 1
fi
ALIAS_NAME="$(basename "$DEST" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$ALIAS_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  echo "Error: '$(basename "$DEST")' can't be an alias name; use letters, digits, '.', '_' or '-'." >&2
  exit 1
fi

# Checked before copying: an existing alias must point at this instance, and a
# new one must not shadow a real command.
BASHRC="${HOME}/.bashrc"
ALIAS_LINE="alias ${ALIAS_NAME}='${DEST}/opencode-run.sh'"
# A commented-out line still counts, so ~/.bashrc never gets a second one.
EXISTING_ALIAS="$(grep -nF "alias ${ALIAS_NAME}=" "$BASHRC" 2>/dev/null | tail -1 || true)"
ALIAS_LINENO="${EXISTING_ALIAS%%:*}"
EXISTING_ALIAS="${EXISTING_ALIAS#*:}"
ALIAS_COMMENTED=0
[[ "$EXISTING_ALIAS" =~ ^[[:space:]]*# ]] && ALIAS_COMMENTED=1
ALIAS_HINT="$(dirname "$DEST")/$(basename "$DEST")-2"
if [[ -n "$EXISTING_ALIAS" && "${EXISTING_ALIAS//\$\{HOME\}/${HOME}}" != *"'${DEST}/opencode-run.sh'"* ]]; then
  if ((ALIAS_COMMENTED)); then
    echo "Error: ${BASHRC} line ${ALIAS_LINENO} has a commented-out '${ALIAS_NAME}' alias for a different directory:" >&2
  else
    echo "Error: the '${ALIAS_NAME}' alias already exists and launches a different instance (${BASHRC} line ${ALIAS_LINENO}):" >&2
  fi
  echo "  ${EXISTING_ALIAS}" >&2
  echo "The alias name comes from the directory name (lowercased), so ${DEST} would need the same '${ALIAS_NAME}' alias." >&2
  echo "Pick a directory with a different name (e.g. ${ALIAS_HINT}), or delete line ${ALIAS_LINENO} of ${BASHRC} and re-run." >&2
  exit 1
fi
if [[ -z "$EXISTING_ALIAS" ]] && command -v "$ALIAS_NAME" >/dev/null; then
  echo "Error: can't create the '${ALIAS_NAME}' alias: '${ALIAS_NAME}' is already a command ($(command -v "$ALIAS_NAME"))." >&2
  echo "The alias would hide that command in every new shell." >&2
  echo "The alias name comes from the directory name (lowercased), so pick a directory with a different name (e.g. ${ALIAS_HINT})." >&2
  exit 1
fi

is_excluded() {
  case "$1" in
    .git*|README.md|AGENTS.md|LICENSE|tests|"$SCRIPT_NAME"|opencode.jsonc.cloud.template|opencode.jsonc.local.template) return 0 ;;
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
      read -r -p "Local backend — [c] llama.cpp (default), [d] Docker Model Runner, or [r] Remote llama.cpp server: " ans
      case "$ans" in
        ""|c|C) BACKEND="cpp"; break ;;
        d|D) BACKEND="dmr"; break ;;
        r|R) BACKEND="remote"; break ;;
        *) echo "Please enter 'c' for llama.cpp, 'd' for Docker Model Runner, or 'r' for a remote llama.cpp server." ;;
      esac
    done
    printf '%s\n' "$BACKEND" > "$BACKEND_FILE"
    echo "Saved local backend: ${BACKEND} -> ${BACKEND_FILE}"
  fi
fi

# Remote backend only: where the standalone llama-server (llama-cpp-run.sh)
# lives, and its optional API key. Delete .remote-llama-url to re-prompt.
REMOTE_URL_FILE="${DEST}/.remote-llama-url"
REMOTE_KEY_FILE="${DEST}/.remote-llama-key"
if [ "$MODE" = "local" ] && [ "$(cat "$BACKEND_FILE")" = "remote" ]; then
  if [ -f "$REMOTE_URL_FILE" ]; then
    echo "Saved remote llama.cpp URL: $(cat "$REMOTE_URL_FILE") (from ${REMOTE_URL_FILE})"
    echo "Delete this file and re-run to change it."
  else
    read -r -p "Remote llama.cpp URL [http://host.docker.internal:8080/v1]: " url
    url="${url:-http://host.docker.internal:8080/v1}"
    printf '%s\n' "$url" > "$REMOTE_URL_FILE"
    read -r -s -p "API key (LLAMA_API_KEY on the server; Enter for none): " key
    echo
    (umask 077 && printf '%s\n' "$key" > "$REMOTE_KEY_FILE")
    echo "Saved remote llama.cpp URL: ${url} -> ${REMOTE_URL_FILE}"
  fi
fi

# Self-heal executable bits in case a previous copy lost them.
[ -f "${DEST}/opencode-run.sh" ] && chmod +x "${DEST}/opencode-run.sh"
[ -f "${DEST}/entrypoint.sh" ]   && chmod +x "${DEST}/entrypoint.sh"
[ -f "${DEST}/llama-cpp-run.sh" ] && chmod +x "${DEST}/llama-cpp-run.sh"

# Install the instance's shell alias in ~/.bashrc if not already present.
if ((ALIAS_COMMENTED)); then
  echo "Alias '${ALIAS_NAME}' is commented out in ${BASHRC} line ${ALIAS_LINENO} — not adding a second one."
  echo "Uncomment that line to use '${ALIAS_NAME}'."
elif [[ -n "$EXISTING_ALIAS" ]]; then
  echo "Alias '${ALIAS_NAME}' already present in ${BASHRC} — skipping."
else
  printf '\n# OpenCode launcher alias (%s)\n%s\n' "$DEST" "$ALIAS_LINE" >> "$BASHRC"
  echo "Added '${ALIAS_NAME}' alias to ${BASHRC}."
  echo "Run 'source ~/.bashrc' or open a new shell to use it."
fi

echo "Done."
