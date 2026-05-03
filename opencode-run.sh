#!/usr/bin/env bash
# Usage: ./opencode-run.sh [/path/to/your/project]
# If no path given, uses current directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTORY_ID="$(echo -n "${SCRIPT_DIR}+${HOSTNAME}" | sha512sum | cut -c1-12)"
WORKSPACE_DIR="${1:-.}"

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
echo "  User:      $(id -un) (PUID=${PUID}, PGID=${PGID})"
echo "---------------------------------------------------"
echo "  Script Directory:    ${SCRIPT_DIR}"
echo "---------------------------------------------------"

export WORKSPACE_DIR
export OC_PROJECT_NAME
export DIRECTORY_ID
cd "${SCRIPT_DIR}"

# Run the container using the generated compose file (docker-compose.yaml should be in the same directory)

docker compose run --rm opencode
