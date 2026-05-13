#!/usr/bin/env bash
# Usage: ./opencode-run.sh [--model SHORTNAME] [/path/to/your/project]
# If no path given, uses current directory.
# If no model given, defaults to "gpt20" (smallest, safest for memory).
# Run with --help for the list of available model shortnames.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTORY_ID="$(echo -n "${SCRIPT_DIR}+${HOSTNAME}" | sha512sum | cut -c1-12)"

# ------------------------------------------------------------------
# Argument parsing: --model SHORTNAME and optional workspace path
# ------------------------------------------------------------------
MODEL_PROFILE="gpt20"
WORKSPACE_ARG=""

# Enumerate available model overlays. Each line is "${prefix}${shortname}".
# Uses a glob (rather than `ls`) so filenames with unusual characters are
# handled correctly.
list_model_overlays() {
  local prefix="${1:-}"
  local f
  for f in "${SCRIPT_DIR}/models/"*.yaml; do
    [[ -f "$f" ]] || continue
    printf '%s%s\n' "$prefix" "$(basename "$f" .yaml)"
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--model SHORTNAME] [PATH]

  --model, -m SHORTNAME   Model overlay to load (default: ${MODEL_PROFILE}).
                          Available overlays:
$(list_model_overlays "                            ")
  --help, -h              Show this help and exit.
  PATH                    Project directory (default: current directory).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model|-m)
      [[ $# -ge 2 ]] || { echo "Error: --model requires an argument" >&2; exit 1; }
      MODEL_PROFILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown flag $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$WORKSPACE_ARG" ]]; then
        WORKSPACE_ARG="$1"
      else
        echo "Error: unexpected extra argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

MODEL_OVERLAY="${SCRIPT_DIR}/models/${MODEL_PROFILE}.yaml"
if [[ ! -f "$MODEL_OVERLAY" ]]; then
  echo "Error: no overlay file for model '${MODEL_PROFILE}' at ${MODEL_OVERLAY}" >&2
  echo "Available overlays:" >&2
  list_model_overlays "  " >&2
  exit 1
fi

WORKSPACE_DIR="${WORKSPACE_ARG:-.}"

# Resolve to absolute path
WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
# Name of project is the current folder
OC_PROJECT_NAME="$(basename "${WORKSPACE_DIR}")"

# Pass host UID/GID at runtime — no rebuild needed
PUID="$(id -u)"
PGID="$(id -g)"
export PUID=${PUID}
export PGID=${PGID}

# Ensure host-side config files exist so Docker doesn't create them as directories
mkdir -p "${HOME}/OpenCode/dot-opencode"
mkdir -p "${HOME}/OpenCode/dot-opencode-json"
mkdir -p "${HOME}/OpenCode/dot-local"
mkdir -p "${HOME}/OpenCode/dot-cache"
mkdir -p "${HOME}/OpenCode/dot-npm"
mkdir -p "${HOME}/OpenCode/dot-ssh"
mkdir -p "${HOME}/OpenCode/dot-gitconfig"
# Create an empty OpenCode config and tui JSON(C) file if missing
touch "${HOME}/OpenCode/dot-opencode-json/opencode.jsonc"
touch "${HOME}/OpenCode/dot-opencode-json/tui.jsonc"

# ------------------------------------------------------------------
# Git config bootstrap – ensure a .gitconfig exists for the container
# ------------------------------------------------------------------
export GIT_CONFIG_GLOBAL="${HOME}/OpenCode/dot-gitconfig/.gitconfig"
if [ ! -f "${HOME}/OpenCode/dot-gitconfig/.gitconfig" ]; then
  echo "No .gitconfig found at ${HOME}/OpenCode/dot-gitconfig/.gitconfig."
  read -r -p "Enter your full name (first and last): " _git_name
  read -r -p "Enter your email address: " _git_email
  git config --global user.name "${_git_name}"
  git config --global user.email "${_git_email}"
else
  echo ".gitconfig already exists – skipping configuration."
fi

# ------------------------------------------------------------------
# SSH‑key bootstrap – ensure a key exists for container use
# ------------------------------------------------------------------
SSH_DIR="${HOME}/OpenCode/dot-ssh"
KEY_PATH="${SSH_DIR}/id_opencode"

# Create the directory if it is missing
mkdir -p -m 700 "$SSH_DIR"

# Only generate a key when it does not already exist
if [ ! -f "$KEY_PATH" ]; then
  echo "No SSH key found at $KEY_PATH."
  read -r -p "Choose key type (rsa4096 / ed25519) – press Enter for rsa4096: " _ssh_key_type
  _ssh_key_type=${_ssh_key_type:-rsa4096}

  case "$_ssh_key_type" in
  rsa4096)
    ssh-keygen -t rsa -b 4096 \
      -C "OpenCode SSH Key" \
      -f "$KEY_PATH" \
      -N ""
    ;;
  ed25519)
    ssh-keygen -t ed25519 \
      -C "OpenCode SSH Key" \
      -f "$KEY_PATH" \
      -N ""
    ;;
  *)
    echo "Unsupported key type. Exiting."
    exit 1
    ;;
  esac

  # Secure the private key
  chmod 600 "$KEY_PATH"

  echo "Generated SSH key at $KEY_PATH."
else
  echo "SSH key already exists at $KEY_PATH – skipping generation."
fi

echo "Starting OpenCode in container..."
echo "  Workspace: ${WORKSPACE_DIR}"
echo "  Config:    ${HOME}/OpenCode/dot-opencode/"
echo "  Model:     ${MODEL_PROFILE} (${MODEL_OVERLAY})"
echo "  User:      $(id -un) (PUID=${PUID}, PGID=${PGID})"
echo "---------------------------------------------------"
echo "  Script Directory:    ${SCRIPT_DIR}"
echo "---------------------------------------------------"

export WORKSPACE_DIR
export OC_PROJECT_NAME
export DIRECTORY_ID
cd "${SCRIPT_DIR}"

# Merge the base compose file with the selected model overlay. The overlay
# contributes the single `models:` binding so Docker Model Runner only ever
# loads one model into memory per run.
docker compose -f docker-compose.yaml -f "models/${MODEL_PROFILE}.yaml" run --rm opencode
