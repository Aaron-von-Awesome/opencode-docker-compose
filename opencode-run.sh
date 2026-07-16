#!/usr/bin/env bash
# Usage: ./opencode-run.sh [--model SHORTNAME] [/path/to/your/project]
# If no path given, uses current directory.
# If --model is given, the matching `models/<shortname>.yaml` overlay is
# merged in and OpenCode runs against Docker Model Runner.
# If --model is omitted, OpenCode runs WITHOUT a local model bound — use
# this when you've configured a cloud/third-party provider in
# opencode.jsonc (see https://opencode.ai/docs/models/).
# Run with --help for the list of available local-model shortnames.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTORY_ID="$(echo -n "${SCRIPT_DIR}+${HOSTNAME}" | sha512sum | cut -c1-12)"

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
MODEL_PROFILE="" # empty => cloud/third-party mode (no overlay)
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

  --model, -m SHORTNAME   Local model overlay to load via Docker Model
                          Runner. If omitted, OpenCode runs without a
                          local model and you should configure a cloud /
                          third-party provider in opencode.jsonc
                          (https://opencode.ai/docs/models/).
                          Available local overlays:
$(list_model_overlays "                            ")
  --help, -h              Show this help and exit.
  PATH                    Project directory (default: current directory).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --model | -m)
    [[ $# -ge 2 ]] || {
      echo "Error: --model requires an argument" >&2
      exit 1
    }
    MODEL_PROFILE="$2"
    shift 2
    ;;
  --help | -h)
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

# ------------------------------------------------------------------
# Local-model preflight (only when --model was given)
# ------------------------------------------------------------------
# Returns the full Docker Model Runner identifier from a given overlay yaml
# (the value of the `model:` key under the top-level `models:` block).
read_overlay_model_id() {
  awk '/^[[:space:]]+model:[[:space:]]+/ {
    sub(/^[[:space:]]+model:[[:space:]]+/, "")
    print
    exit
  }' "$1"
}

# Normalize a model identifier to the canonical form reported by
# `docker model ps` under the MODEL column:
#   - strip a leading "ai/" prefix (the default Docker Model Runner
#     registry, which is omitted in CLI output)
#   - lowercase the rest
# Examples:
#   "ai/gpt-oss:20B-F16"                            -> "gpt-oss:20b-f16"
#   "ai/gemma4:31B"                                 -> "gemma4:31b"
#   "huggingface.co/unsloth/gpt-oss-120b-gguf:F16"  -> "huggingface.co/unsloth/gpt-oss-120b-gguf:f16"
# Non-default registries (containing a "." in the first path segment,
# e.g. huggingface.co/...) are kept intact — only the implicit "ai/"
# registry is stripped by Docker Model Runner.
normalize_model_id() {
  local id="${1#ai/}"
  printf '%s\n' "${id,,}"
}

# Returns currently-loaded Docker Model Runner models in canonical short
# form, one identifier per line. Empty output means "nothing loaded" or
# "Model Runner unavailable".
#
# Docker Model Runner can interleave pull-progress lines (e.g. layer IDs
# and "Status:", "Successfully", etc.) before the actual `docker model ps`
# table when the CLI plugin auto-updates on invocation. A naive
# "skip line 1" parser captures those as bogus model identifiers, so we:
#   1. Anchor on the literal "MODEL NAME" header to find the real table.
#   2. Apply a regex sanity filter so only strings that look like model
#      identifiers (lowercase alphanumerics, optional `name:tag` shape
#      with a non-empty tag) get through.
list_loaded_models() {
  docker model ps 2>/dev/null | awk '
    /^MODEL[[:space:]]+NAME/ { in_table = 1; next }
    in_table && NF > 0 && $1 ~ /^[a-z0-9._/-]+(:[a-z0-9._-]+)?$/ { print $1 }
  '
}

# Given a canonical (lowercased) model identifier as reported by
# `docker model ps`, return the case-preserved name reported by
# `docker model list`. This indirection is required because
# `docker model unload` is case-sensitive and only accepts the
# case-preserved form (e.g. `gemma4:31B`, not `gemma4:31b`).
# Echoes the canonical input verbatim if no `list` entry matches
# (so the caller can still attempt the unload).
resolve_to_list_name() {
  local canonical="$1"
  local match
  match="$(
    docker model list 2>/dev/null | awk -v target="$canonical" '
      NR>1 && NF>0 && tolower($1) == target { print $1; exit }
    '
  )"
  printf '%s\n' "${match:-$canonical}"
}

MODEL_OVERLAY=""
REQUESTED_MODEL_ID=""

if [[ -n "$MODEL_PROFILE" ]]; then
  MODEL_OVERLAY="${SCRIPT_DIR}/models/${MODEL_PROFILE}.yaml"
  if [[ ! -f "$MODEL_OVERLAY" ]]; then
    echo "Error: no overlay file for model '${MODEL_PROFILE}' at ${MODEL_OVERLAY}" >&2
    echo "Available overlays:" >&2
    list_model_overlays "  " >&2
    exit 1
  fi

  REQUESTED_MODEL_ID="$(read_overlay_model_id "$MODEL_OVERLAY")"
  if [[ -z "$REQUESTED_MODEL_ID" ]]; then
    echo "Error: could not read the 'model:' field from ${MODEL_OVERLAY}" >&2
    exit 1
  fi
  REQUESTED_CANONICAL="$(normalize_model_id "$REQUESTED_MODEL_ID")"

  loaded="$(list_loaded_models)"
  # Filter out the requested model (compare in canonical form); what
  # remains is "other models that are currently loaded and would consume
  # memory alongside the requested one".
  others=""
  if [[ -n "$loaded" ]]; then
    others="$(grep -vFx -- "$REQUESTED_CANONICAL" <<<"$loaded" | grep -v '^[[:space:]]*$' || true)"
  fi

  if [[ -n "$others" ]]; then
    echo "Different Docker Model Runner model(s) are currently loaded:"
    while IFS= read -r m; do
      [[ -n "$m" ]] && echo "    $m"
    done <<<"$others"
    echo "You requested:"
    echo "    ${REQUESTED_MODEL_ID}  (canonical: ${REQUESTED_CANONICAL})"
    echo
    echo "Continuing will unload the other model(s) via 'docker model unload'"
    echo "to free memory before starting OpenCode."
    echo
    read -r -p "Continue (unload others, then start)? [y/N]: " _ans
    case "$_ans" in
    y | Y | yes | YES)
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        # `docker model ps` reports lowercased names, but
        # `docker model unload` requires the case-preserved name from
        # `docker model list` — look it up here.
        target="$(resolve_to_list_name "$m")"
        if [[ "$target" != "$m" ]]; then
          echo "Unloading: ${target}  (loaded as ${m})"
        else
          echo "Unloading: ${target}"
        fi
        docker model unload "$target" || echo "  (unload failed for ${target} — continuing anyway)" >&2
      done <<<"$others"
      ;;
    *)
      echo "Aborted."
      exit 1
      ;;
    esac
  fi
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

# Ensure host-side directories exist so Docker doesn't create them as
# directories with root ownership at mount time.
mkdir -p "${HOME}/OpenCode/dot-config/opencode"
mkdir -p "${HOME}/OpenCode/dot-local"
mkdir -p "${HOME}/OpenCode/dot-cache"
mkdir -p "${HOME}/OpenCode/dot-npm"
mkdir -p "${HOME}/OpenCode/dot-ssh"
mkdir -p "${HOME}/OpenCode/dot-gitconfig"

# Move (not copy) the canonical .jsonc templates from the script root
# into OpenCode's default config location (~/.config/opencode/). The
# script root acts as a transient handoff slot: after the first launch
# it's empty, and subsequent launches skip the move silently — the
# already-seeded files at the destination keep being honored by OpenCode.
# To push an updated config, re-run `opencode-init.sh` to re-copy the
# canonical templates from the cloned repo into the script root, then
# `opencode-run.sh` will move them into place on the next launch.
for _pair in "opencode.jsonc.template:opencode.jsonc" "tui.jsonc:tui.jsonc"; do
  _src_name="${_pair%%:*}"
  _dst_name="${_pair##*:}"
  _src="${SCRIPT_DIR}/${_src_name}"
  if [ -f "$_src" ]; then
    mv -f "$_src" "${HOME}/OpenCode/dot-config/opencode/${_dst_name}"
  fi
done
unset _pair _src_name _dst_name _src

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
echo "  Config:    ${HOME}/OpenCode/dot-config/"
if [[ -n "$MODEL_PROFILE" ]]; then
  echo "  Model:     ${MODEL_PROFILE} -> ${REQUESTED_MODEL_ID}"
else
  echo "  Model:     (none — cloud/third-party mode; see opencode.jsonc)"
fi
echo "  User:      $(id -un) (PUID=${PUID}, PGID=${PGID})"
echo "---------------------------------------------------"
echo "  Script Directory:    ${SCRIPT_DIR}"
echo "---------------------------------------------------"

export WORKSPACE_DIR
export OC_PROJECT_NAME
export DIRECTORY_ID
cd "${SCRIPT_DIR}"

# Build the compose invocation. The base compose file has no `models:`
# bindings; if a local model was selected, merge in the matching overlay
# so Docker Model Runner sees exactly one binding (and loads exactly one
# model into memory). If no --model was given, launch without an overlay
# and let OpenCode use whatever provider opencode.jsonc points at.
COMPOSE_ARGS=(-f docker-compose.yaml)
if [[ -n "$MODEL_PROFILE" ]]; then
  COMPOSE_ARGS+=(-f "models/${MODEL_PROFILE}.yaml")
fi

docker compose "${COMPOSE_ARGS[@]}" run --rm opencode
