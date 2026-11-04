#!/usr/bin/env bash
# Usage: ./opencode-run.sh [--model SHORTNAME] [/path/to/your/project]
# Path defaults to the current directory. --model merges
# models/<backend>/<shortname>.yaml, where <backend> (cpp = llama.cpp,
# dmr = Docker Model Runner) is read from .local-backend (set by
# opencode-init.sh). With the remote backend, --model is not used: OpenCode
# connects to the standalone llama-server in .remote-llama-url. Otherwise,
# without --model, OpenCode uses the provider in opencode.jsonc (cloud mode).
# --help lists the available shortnames.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRECTORY_ID="$(echo -n "${HOSTNAME}" | sha512sum | cut -c1-12)"

# shellcheck source=llama-cpp-lib.sh
source "${SCRIPT_DIR}/llama-cpp-lib.sh"

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
MODEL_PROFILE="" # empty => cloud/third-party mode (no overlay)
WORKSPACE_ARG=""

# Local-model backend from opencode-init.sh; missing file means cpp.
LOCAL_BACKEND="$(cat "${SCRIPT_DIR}/.local-backend" 2>/dev/null || echo cpp)"
case "$LOCAL_BACKEND" in
cpp | dmr | remote) ;;
*)
  echo "Error: unknown backend '${LOCAL_BACKEND}' in ${SCRIPT_DIR}/.local-backend (expected cpp, dmr or remote)" >&2
  exit 1
  ;;
esac

# remote: connect to a standalone llama-server (llama-cpp-run.sh) instead of
# starting one. Only applies in local config mode; a stale .local-backend
# left behind after switching to cloud is ignored.
CONFIG_MODE="$(cat "${SCRIPT_DIR}/.config-mode" 2>/dev/null || true)"
REMOTE_LLAMA=0
if [[ "$LOCAL_BACKEND" == "remote" && "$CONFIG_MODE" == "local" ]]; then
  REMOTE_LLAMA=1
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [--model SHORTNAME] [PATH]

  --model, -m SHORTNAME   Local model overlay to serve via the backend
                          chosen in opencode-init.sh (llama.cpp or Docker
                          Model Runner). If omitted, OpenCode runs without a
                          local model and you should configure a cloud /
                          third-party provider in opencode.jsonc
                          (https://opencode.ai/v2/docs/models/).
                          Not used with the remote backend: OpenCode connects
                          to whatever model the standalone server is serving.
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

# The cloud template has no "active" provider, so a local model would load
# onto the GPU and never be used.
if [[ -n "$MODEL_PROFILE" && "$CONFIG_MODE" == "cloud" ]]; then
  echo "Error: --model isn't used in cloud mode. To switch to local, delete ${SCRIPT_DIR}/.config-mode and re-run opencode-init.sh." >&2
  exit 1
fi

if [[ "$REMOTE_LLAMA" -eq 1 ]]; then
  if [[ -n "$MODEL_PROFILE" ]]; then
    echo "Error: --model isn't used with the remote backend; pick the model on the server (llama-cpp-run.sh --model ...)." >&2
    exit 1
  fi
  ACTIVE_MODEL_URL="$(cat "${SCRIPT_DIR}/.remote-llama-url" 2>/dev/null || true)"
  ACTIVE_MODEL_API_KEY="$(cat "${SCRIPT_DIR}/.remote-llama-key" 2>/dev/null || true)"
  if [[ -z "$ACTIVE_MODEL_URL" ]]; then
    echo "Error: no server URL in ${SCRIPT_DIR}/.remote-llama-url. Delete .local-backend and re-run opencode-init.sh." >&2
    exit 1
  fi
  # host.docker.internal only resolves inside the container; probe via localhost.
  probe_url="${ACTIVE_MODEL_URL/host.docker.internal/localhost}"
  probe_url="${probe_url%/}"
  # The key goes in via stdin (-H @-) so it never shows up in `ps`.
  remote_curl() {
    if [[ -n "$ACTIVE_MODEL_API_KEY" ]]; then
      printf 'Authorization: Bearer %s\n' "$ACTIVE_MODEL_API_KEY" | curl -H @- "$@"
    else
      curl "$@"
    fi
  }
  models_json="$(remote_curl -sf --max-time 5 "${probe_url}/models" || true)"
  if [[ -z "$models_json" ]]; then
    echo "Error: can't reach the llama.cpp server at ${probe_url}/models (wrong URL or server down)." >&2
    exit 1
  fi
  # /models stays open even with an API key, so check the key on a protected
  # path: a GET there is 401 with a bad/missing key, 404/405 with a good one.
  auth_code="$(remote_curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${probe_url}/chat/completions" || true)"
  if [[ "$auth_code" == "401" ]]; then
    echo "Error: the llama.cpp server at ${probe_url} rejected the API key. Fix ${SCRIPT_DIR}/.remote-llama-key (or LLAMA_API_KEY on the server)." >&2
    exit 1
  fi
  ACTIVE_MODEL_NAME="$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$models_json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  if [[ -z "$ACTIVE_MODEL_NAME" ]]; then
    echo "Error: the server at ${probe_url}/models reports no model." >&2
    exit 1
  fi
  ACTIVE_MODEL_DISPLAY_NAME="$ACTIVE_MODEL_NAME"
  export ACTIVE_MODEL_URL ACTIVE_MODEL_NAME ACTIVE_MODEL_DISPLAY_NAME ACTIVE_MODEL_API_KEY
fi

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
mkdir -p "${SCRIPT_DIR}"/{container-tmp,development,dot-cache,dot-config/opencode,dot-gitconfig,dot-local,dot-npm}
# Own line so only dot-ssh (private key) gets 700.
mkdir -p -m 700 "${SCRIPT_DIR}/dot-ssh"

# Move (not copy) templates left at the script root by opencode-init.sh into
# dot-config/opencode/, backing up any existing file. After the first launch
# the slot is empty and this is a no-op; re-run opencode-init.sh to refill it.
for _pair in "opencode.jsonc.template:opencode.jsonc" "cli.json.template:cli.json"; do
  _src_name="${_pair%%:*}"
  _dst_name="${_pair##*:}"
  _src="${SCRIPT_DIR}/${_src_name}"
  _dst="${SCRIPT_DIR}/dot-config/opencode/${_dst_name}"
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
      cp "$_dst" "${SCRIPT_DIR}/dot-config/opencode/${_ts}_${_dst_name}.backup"
    fi
    mv -f "$_src" "$_dst"
  fi
done
unset _pair _src_name _dst_name _src _dst _ts _ans

# An opencode.jsonc from before the remote backend has no apiKey line, so
# OpenCode would send no key even though the probe above passed.
if [[ "$REMOTE_LLAMA" -eq 1 && -n "$ACTIVE_MODEL_API_KEY" ]] &&
  ! grep -q ACTIVE_MODEL_API_KEY "${SCRIPT_DIR}/dot-config/opencode/opencode.jsonc" 2>/dev/null; then
  echo "Error: ${SCRIPT_DIR}/dot-config/opencode/opencode.jsonc has no apiKey line, so OpenCode can't send the API key." >&2
  echo "Re-run opencode-init.sh and answer 'y' to overwrite opencode.jsonc on the next launch." >&2
  exit 1
fi

# ------------------------------------------------------------------
# Git config bootstrap – ensure a .gitconfig exists for the container
# ------------------------------------------------------------------
export GIT_CONFIG_GLOBAL="${SCRIPT_DIR}/dot-gitconfig/.gitconfig"
if [ ! -f "${SCRIPT_DIR}/dot-gitconfig/.gitconfig" ]; then
  echo "No .gitconfig found at ${SCRIPT_DIR}/dot-gitconfig/.gitconfig."
  while :; do
    read -r -p "Enter your full name (first and last): " _git_name || exit 1
    [[ -n "${_git_name// }" ]] && break
    echo "Name can't be empty."
  done
  while :; do
    read -r -p "Enter your email address: " _git_email || exit 1
    [[ -n "${_git_email// }" ]] && break
    echo "Email can't be empty."
  done
  git config --global user.name "${_git_name}"
  git config --global user.email "${_git_email}"
else
  echo ".gitconfig already exists – skipping configuration."
fi

# ------------------------------------------------------------------
# SSH‑key bootstrap – ensure a key exists for container use
# ------------------------------------------------------------------
SSH_DIR="${SCRIPT_DIR}/dot-ssh"
KEY_PATH="${SSH_DIR}/id_opencode"

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
# SSH only tries default key names (id_rsa, id_ed25519, ...) on its own.
# umask 077: ssh rejects a group-writable config (umask 002 would make one).
[[ -f "${SSH_DIR}/config" ]] || (umask 077 && printf 'IdentityFile ~/.ssh/id_opencode\n' >"${SSH_DIR}/config")

EXTRA_COMPOSE=""
if [[ -f "${WORKSPACE_DIR}/extra-compose.yaml" ]]; then
  EXTRA_COMPOSE="${WORKSPACE_DIR}/extra-compose.yaml"
fi

echo "Starting OpenCode in container..."
echo "  Workspace: ${WORKSPACE_DIR}"
echo "  Config:    ${SCRIPT_DIR}/dot-config/"
if [[ -n "$MODEL_PROFILE" ]]; then
  echo "  Model:     ${MODEL_PROFILE} (${LOCAL_BACKEND}) -> ${GGUF_FILE:-${REQUESTED_MODEL_ID}}"
elif [[ "$REMOTE_LLAMA" -eq 1 ]]; then
  echo "  Model:     ${ACTIVE_MODEL_NAME} (remote) -> ${ACTIVE_MODEL_URL}"
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
  # GPU from opencode-init.sh; missing file means rocm.
  gpu_file="$(llama_gpu_file "$(cat "${SCRIPT_DIR}/.llama-gpu" 2>/dev/null || echo rocm)")" || exit 1
  COMPOSE_ARGS+=(-f docker-compose.llama-cpp.yaml ${gpu_file:+-f "$gpu_file"})
else
  # The shared llama-server (another cpp session/instance, same project) isn't in this file set.
  export COMPOSE_IGNORE_ORPHANS=true
fi
if [[ -n "$MODEL_PROFILE" ]]; then
  COMPOSE_ARGS+=(-f "models/${LOCAL_BACKEND}/${MODEL_PROFILE}.yaml")
fi

# Optional per-project extra-compose.yaml may modify services but not add any.
# The agent can write the workspace, so new or changed content needs a human
# OK. Compose reads the approved copy in the instance dir, which the agent
# can't reach, so the file can't change between approval and launch.
if [[ -n "$EXTRA_COMPOSE" ]]; then
  APPROVED_DIR="${SCRIPT_DIR}/.approved-extra-compose"
  mkdir -p "$APPROVED_DIR"
  _tmp="$(mktemp "${APPROVED_DIR}/.new.XXXXXX")"
  # Compose resolves extends:/include: here, so the approved copy loads no
  # other file the agent could edit later. Its `name:` would override the
  # project name (opencode-va), so it's dropped.
  if ! docker compose --project-directory "$SCRIPT_DIR" -f "$EXTRA_COMPOSE" config --no-interpolate --no-normalize --no-consistency --no-path-resolution |
    grep -v '^name:' >"$_tmp"; then
    rm "$_tmp"
    echo "Error: docker compose can't read ${EXTRA_COMPOSE}." >&2
    exit 1
  fi
  _approved="${APPROVED_DIR}/$(sha256sum "$_tmp" | cut -d' ' -f1).yaml"
  if [[ -f "$_approved" ]]; then
    rm "$_tmp"
  else
    echo "New or changed ${EXTRA_COMPOSE}:"
    # cat -v shows control codes, so escape sequences can't hide lines.
    sed 's/^/    /' "$_tmp" | cat -v
    read -r -p "Merge it into the launch? It can change mounts and privileges. [y/N]: " _ans || _ans=""
    case "$_ans" in
    y | Y | yes | YES) mv "$_tmp" "$_approved" ;;
    *)
      rm "$_tmp"
      echo "Aborted." >&2
      exit 1
      ;;
    esac
  fi
  EXTRA_COMPOSE="$_approved"
  base_services="$(docker compose "${COMPOSE_ARGS[@]}" config --services)"
  COMPOSE_ARGS+=(-f "$EXTRA_COMPOSE")
  all_services="$(docker compose "${COMPOSE_ARGS[@]}" config --services)"
  if added="$(grep -vxF -f <(printf '%s\n' "$base_services") <<<"$all_services")"; then
    echo "Error: extra-compose.yaml adds service(s): ${added//$'\n'/, }. It may only modify existing services." >&2
    exit 1
  fi
fi

RUN_ARGS=(run --rm)

# Name-only -e reads the exported values, keeping the key off the command line.
if [[ "$REMOTE_LLAMA" -eq 1 || ( -n "$MODEL_PROFILE" && "$LOCAL_BACKEND" == "cpp" ) ]]; then
  RUN_ARGS+=(-e ACTIVE_MODEL_URL -e ACTIVE_MODEL_NAME -e ACTIVE_MODEL_DISPLAY_NAME)
fi
if [[ "$REMOTE_LLAMA" -eq 1 ]]; then
  RUN_ARGS+=(-e ACTIVE_MODEL_API_KEY)
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
