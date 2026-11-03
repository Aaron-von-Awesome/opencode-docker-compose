#!/usr/bin/env bash
# Usage: ./opencode-run.sh [--model SHORTNAME] [/path/to/your/project]
# Path defaults to the current directory. --model merges
# models/<backend>/<shortname>.yaml, where <backend> (cpp = llama.cpp,
# dmr = Docker Model Runner) is read from .local-backend (set by
# opencode-init.sh). Without --model, OpenCode uses the provider in
# opencode.jsonc (cloud mode). --help lists the available shortnames.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTORY_ID="$(echo -n "${SCRIPT_DIR}+${HOSTNAME}" | sha512sum | cut -c1-12)"

# shellcheck source=llama-cpp-lib.sh
source "${SCRIPT_DIR}/llama-cpp-lib.sh"
usage() {
  cat <<EOF
Usage: $(basename "$0") [--model SHORTNAME] [PATH]

  --model, -m SHORTNAME   Local model overlay to serve via the backend
                          chosen in opencode-init.sh (llama.cpp or Docker
                          Model Runner). If omitted, OpenCode runs without a
                          local model and you should configure a cloud /
                          third-party provider in opencode.jsonc
                          (https://opencode.ai/v2/docs/models/).
                          Available local overlays (backend: ${LOCAL_BACKEND}):
$(list_model_overlays "$LOCAL_BACKEND" "                            ")
  --help, -h              Show this help and exit.
  PATH                    Project directory (default: current directory).

Environment:
  OPENCODE_GGUF_DIR       llama.cpp only: host folder holding the GGUF files
                          (default: /mnt/storage/llama-cpp/models).

Workspace Customization:
  If the workspace directory contains an extra-compose.yaml file, it is
  merged into the compose invocation. This enables per-project OpenCode
  service customization (e.g., joining external Docker networks, adding
  volumes, environment variables, etc.).

  Validation: extra-compose.yaml may modify existing services (opencode,
  and llama-server with llama.cpp) but must NOT add new ones.

  Example extra-compose.yaml (joining external network):
    services:
      opencode:
        networks:
          - kiwifs-net

    networks:
      kiwifs-net:
        external: true
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
# dmr: prints the overlay's `models.llm_active.model` identifier.
read_overlay_model_id() {
  awk '/^[[:space:]]+model:[[:space:]]+/ {
    sub(/^[[:space:]]+model:[[:space:]]+/, "")
    print
    exit
  }' "$1"
}

# Matches `docker model ps` output: drops the implicit "ai/" prefix, lowercases.
normalize_model_id() {
  local id="${1#ai/}"
  printf '%s\n' "${id,,}"
}

# Prints loaded DMR models (canonical form), one per line; empty if none or
# DMR is unavailable. The CLI plugin can print pull-progress lines before the
# table when it auto-updates, so anchor on the "MODEL NAME" header and only
# accept identifier-shaped values.
list_loaded_models() {
  docker model ps 2>/dev/null | awk '
    /^MODEL[[:space:]]+NAME/ { in_table = 1; next }
    in_table && NF > 0 && $1 ~ /^[a-z0-9._/-]+(:[a-z0-9._-]+)?$/ { print $1 }
  '
}

# Maps a lowercased `docker model ps` name to the case-preserved name from
# `docker model list`, which `docker model unload` requires (e.g. `gemma4:31B`).
# Falls back to the input if no match.
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

GGUF_FILE=""
REQUESTED_MODEL_ID=""

if [[ -n "$MODEL_PROFILE" ]]; then
  MODEL_OVERLAY="${SCRIPT_DIR}/models/${LOCAL_BACKEND}/${MODEL_PROFILE}.yaml"
  if [[ ! -f "$MODEL_OVERLAY" ]]; then
    echo "Error: no ${LOCAL_BACKEND} overlay for model '${MODEL_PROFILE}' at ${MODEL_OVERLAY}" >&2
    echo "Available overlays:" >&2
    list_model_overlays "$LOCAL_BACKEND" "  " >&2
    exit 1
  fi
fi

if [[ -n "$MODEL_PROFILE" && "$LOCAL_BACKEND" == "cpp" ]]; then
  llama_preflight "$MODEL_OVERLAY"

  # Passed to OpenCode with `run -e`; the display name is the overlay's
  # llama-server label, so overlays don't define an opencode service.
  ACTIVE_MODEL_URL="http://llama-server:8080/v1"
  ACTIVE_MODEL_NAME="$MODEL_PROFILE"
  ACTIVE_MODEL_DISPLAY_NAME="$(awk -F'"' '/^[[:space:]]+opencode\.display-name:/ {print $2; exit}' "$MODEL_OVERLAY")"
  ACTIVE_MODEL_DISPLAY_NAME="${ACTIVE_MODEL_DISPLAY_NAME:-$MODEL_PROFILE}"
  export ACTIVE_MODEL_URL ACTIVE_MODEL_NAME ACTIVE_MODEL_DISPLAY_NAME
fi

if [[ -n "$MODEL_PROFILE" && "$LOCAL_BACKEND" == "dmr" ]]; then
  REQUESTED_MODEL_ID="$(read_overlay_model_id "$MODEL_OVERLAY")"
  if [[ -z "$REQUESTED_MODEL_ID" ]]; then
    echo "Error: could not read the 'model:' field from ${MODEL_OVERLAY}" >&2
    exit 1
  fi
  REQUESTED_CANONICAL="$(normalize_model_id "$REQUESTED_MODEL_ID")"

  loaded="$(list_loaded_models)"
  # Loaded models other than the requested one.
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
WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
OC_PROJECT_NAME="$(basename "${WORKSPACE_DIR}")"

# entrypoint.sh remaps abc to these at runtime — no rebuild needed.
PUID="$(id -u)"
PGID="$(id -g)"
export PUID=${PUID}
export PGID=${PGID}

# Pre-create mount sources so Docker doesn't create them root-owned.
mkdir -p "${HOME}/OpenCode/container-tmp"
mkdir -p "${HOME}/OpenCode/development"
mkdir -p "${HOME}/OpenCode/dot-cache"
mkdir -p "${HOME}/OpenCode/dot-config/opencode"
mkdir -p "${HOME}/OpenCode/dot-gitconfig"
mkdir -p "${HOME}/OpenCode/dot-local"
mkdir -p "${HOME}/OpenCode/dot-npm"
mkdir -p "${HOME}/OpenCode/dot-ssh"

# Move (not copy) templates left at the script root by opencode-init.sh into
# dot-config/opencode/, backing up any existing file. After the first launch
# the slot is empty and this is a no-op; re-run opencode-init.sh to refill it.
for _pair in "opencode.jsonc.template:opencode.jsonc" "cli.json.template:cli.json"; do
  _src_name="${_pair%%:*}"
  _dst_name="${_pair##*:}"
  _src="${SCRIPT_DIR}/${_src_name}"
  _dst="${HOME}/OpenCode/dot-config/opencode/${_dst_name}"
  if [ -f "$_src" ]; then
    if [ -f "$_dst" ]; then
      read -r -p "  ${_dst_name} exists. Overwrite? [y/N]: " _ans
      case "$_ans" in
      y | Y | yes | YES) ;;
      *)
        rm "$_src"
        continue
        ;;
      esac
      _ts="$(date +%Y%m%d-%H%M%S)"
      cp "$_dst" "${HOME}/OpenCode/dot-config/opencode/${_ts}_${_dst_name}.backup"
    fi
    mv -f "$_src" "$_dst"
  fi
done
unset _pair _src_name _dst_name _src _dst _ts _ans

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

mkdir -p -m 700 "$SSH_DIR"

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

  chmod 600 "$KEY_PATH"

  echo "Generated SSH key at $KEY_PATH."
else
  echo "SSH key already exists at $KEY_PATH – skipping generation."
fi

EXTRA_COMPOSE=""
if [[ -f "${WORKSPACE_DIR}/extra-compose.yaml" ]]; then
  EXTRA_COMPOSE="${WORKSPACE_DIR}/extra-compose.yaml"
fi

echo "Starting OpenCode in container..."
echo "  Workspace: ${WORKSPACE_DIR}"
echo "  Config:    ${HOME}/OpenCode/dot-config/"
if [[ -n "$MODEL_PROFILE" ]]; then
  echo "  Model:     ${MODEL_PROFILE} (${LOCAL_BACKEND}) -> ${GGUF_FILE:-${REQUESTED_MODEL_ID}}"
else
  echo "  Model:     (none — cloud/third-party mode; see opencode.jsonc)"
fi
echo "  User:      $(id -un) (PUID=${PUID}, PGID=${PGID})"
echo "---------------------------------------------------"
echo "  Script Directory:    ${SCRIPT_DIR}"
if [[ -n "$EXTRA_COMPOSE" ]]; then
  echo "  Extra Compose: ${EXTRA_COMPOSE}"
fi
echo "---------------------------------------------------"

export WORKSPACE_DIR
export OC_PROJECT_NAME
export DIRECTORY_ID
cd "${SCRIPT_DIR}"

# The base file has no model backend. With --model, cpp adds the llama-server
# service; every backend adds its one overlay. extra-compose.yaml goes last.
COMPOSE_ARGS=(-f docker-compose.yaml)
if [[ -n "$MODEL_PROFILE" && "$LOCAL_BACKEND" == "cpp" ]]; then
  COMPOSE_ARGS+=(-f docker-compose.llama-cpp.yaml)
fi
if [[ -n "$MODEL_PROFILE" ]]; then
  COMPOSE_ARGS+=(-f "models/${LOCAL_BACKEND}/${MODEL_PROFILE}.yaml")
fi

# Optional per-project extra-compose.yaml may modify services but not add any.
if [[ -n "$EXTRA_COMPOSE" ]]; then
  base_services="$(docker compose "${COMPOSE_ARGS[@]}" config --services)"
  COMPOSE_ARGS+=(-f "$EXTRA_COMPOSE")
  all_services="$(docker compose "${COMPOSE_ARGS[@]}" config --services)"
  if added="$(grep -vxF -f <(printf '%s\n' "$base_services") <<<"$all_services")"; then
    echo "Error: extra-compose.yaml adds service(s): ${added//$'\n'/, }. It may only modify existing services." >&2
    exit 1
  fi
fi

RUN_ARGS=(run --rm)

# Name-only -e reads the exported values, keeping them off the command line.
if [[ -n "$MODEL_PROFILE" && "$LOCAL_BACKEND" == "cpp" ]]; then
  RUN_ARGS+=(-e ACTIVE_MODEL_URL -e ACTIVE_MODEL_NAME -e ACTIVE_MODEL_DISPLAY_NAME)
fi

if [[ -n "$MODEL_PROFILE" && "$LOCAL_BACKEND" == "cpp" ]]; then
  # llama.cpp sessions are labeled so the last one out stops llama-server.
  RUN_ARGS+=(-l opencode.uses-llama=true)

  count_llama_sessions() {
    docker ps -q --filter label=opencode.uses-llama=true | wc -l
  }

  # shortcut: a session that exits while another is still starting can stop
  # the server under it; add a lock if concurrent launches become common.
  stop_llama_if_unused() {
    if [[ "$(count_llama_sessions)" -eq 0 ]]; then
      echo "No other OpenCode sessions use llama-server — stopping it."
      docker stop llama-server >/dev/null 2>&1 || true
      docker rm llama-server >/dev/null 2>&1 || true
    else
      echo "Other OpenCode sessions still use llama-server — leaving it running."
    fi
  }
  sessions="$(count_llama_sessions)"
  warning=""
  if [[ "$sessions" -gt 0 ]]; then
    warning="${sessions} other OpenCode session(s) use it and will lose their model."
  fi
  llama_start_or_reuse llama-server "$warning" "${COMPOSE_ARGS[@]}" || [[ $? -eq 10 ]]
  trap stop_llama_if_unused EXIT
  llama_wait_healthy llama-server "docker logs llama-server"
fi

docker compose "${COMPOSE_ARGS[@]}" "${RUN_ARGS[@]}" opencode
