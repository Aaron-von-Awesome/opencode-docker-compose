# Shared llama.cpp start-up steps, sourced by opencode-run.sh (per-session
# llama-server) and llama-cpp-run.sh (standalone). Uses $MODEL_PROFILE and
# $SCRIPT_DIR.

# Usage: list_model_overlays BACKEND PREFIX
# Prints PREFIX + shortname for each models/BACKEND/*.yaml under $SCRIPT_DIR.
list_model_overlays() {
  local f
  for f in "${SCRIPT_DIR}/models/$1/"*.yaml; do
    [[ -f "$f" ]] || continue
    printf '%s%s\n' "$2" "$(basename "$f" .yaml)"
  done
}

# Prints the overlay's LLAMA_ARG_MODEL filename, relative to the GGUF dir.
read_overlay_gguf() {
  awk '/^[[:space:]]+LLAMA_ARG_MODEL:[[:space:]]+/ {
    sub(/^[[:space:]]+LLAMA_ARG_MODEL:[[:space:]]+/, "")
    gsub(/"/, "")
    sub(/^\/mnt\/storage\/llama-cpp\/models\//, "")
    print
    exit
  }' "$1"
}

# Sets GGUF_FILE from the overlay and exits unless the file exists; exports
# what the compose files interpolate: OPENCODE_GGUF_DIR, VIDEO_GID,
# RENDER_GID and MODEL_PROFILE. GGUF_FILE stays local (the full path is
# hardcoded in the overlays, and the launcher echoes it itself).
llama_preflight() {
  local overlay="$1"
  GGUF_FILE="$(read_overlay_gguf "$overlay")"
  if [[ -z "$GGUF_FILE" ]]; then
    echo "Error: could not read 'LLAMA_ARG_MODEL' from ${overlay}" >&2
    exit 1
  fi
  export OPENCODE_GGUF_DIR="${OPENCODE_GGUF_DIR:-/mnt/storage/llama-cpp/models}"
  if [[ ! -f "${OPENCODE_GGUF_DIR}/${GGUF_FILE}" ]]; then
    echo "Error: GGUF not found: ${OPENCODE_GGUF_DIR}/${GGUF_FILE}" >&2
    echo "Download it there, or set OPENCODE_GGUF_DIR." >&2
    exit 1
  fi
  # Host GIDs that own /dev/kfd and /dev/dri; compose falls back to 44/992.
  VIDEO_GID="$(getent group video | cut -d: -f3 || true)"
  RENDER_GID="$(getent group render | cut -d: -f3 || true)"
  export VIDEO_GID RENDER_GID MODEL_PROFILE
}

# Usage: llama_gpu_file GPU
# Prints the compose file to merge after docker-compose.llama-cpp.yaml for
# GPU (nothing for rocm, the base file's default). Fails on unknown values.
llama_gpu_file() {
  case "$1" in
  rocm) ;;
  vulkan) echo docker-compose.llama-cpp.vulkan.yaml ;;
  *)
    echo "Error: unknown GPU '$1' (expected rocm or vulkan)" >&2
    return 1
    ;;
  esac
}

# Usage: llama_start_or_reuse CONTAINER WARNING COMPOSE_ARGS...
# Reuses CONTAINER only on an exact Compose config-hash match (so edited
# overlay flags aren't silently ignored); otherwise prints WARNING, asks,
# and recreates it. Returns 10 on reuse, 11 on "no" (the declined restart
# must not fire a caller's EXIT trap and remove the healthy server, so it
# returns instead of exiting — llama-cpp-run.sh clears its trap on 11), and
# 12 when compose can't compute the config hash: fail-fast, nothing changed,
# a running healthy server is left untouched. Callers under `set -e` must
# handle all three: `llama_start_or_reuse ... || [[ $? -eq 10 ]]`.
llama_start_or_reuse() {
  local container="$1" warning="$2"
  shift 2
  local running running_model running_hash wanted_hash ans
  running="$(docker inspect -f '{{if .State.Running}}{{index .Config.Labels "opencode.model"}} {{index .Config.Labels "com.docker.compose.config-hash"}}{{end}}' "$container" 2>/dev/null || true)"
  running_model="${running% *}"
  running_hash="${running##* }"
  # Explicit: callers use `|| ...`, which disables set -e inside this function.
  wanted_hash="$(docker compose "$@" config --hash llama-server | awk '{print $2}')" || {
    echo "Error: docker compose can't compute the llama-server config hash (bad overlay or merge file?); leaving any running server untouched." >&2
    return 12
  }
  if [[ -n "$running" && "$running_hash" == "$wanted_hash" ]]; then
    echo "Reusing running ${container} (${MODEL_PROFILE})."
    return 10
  fi
  if [[ -n "$running" ]]; then
    if [[ "$running_model" == "$MODEL_PROFILE" ]]; then
      echo "${container} is running '${running_model}' with an older config."
    else
      echo "${container} is running '${running_model}'; you requested '${MODEL_PROFILE}'."
    fi
    [[ -n "$warning" ]] && echo "$warning"
    read -r -p "Restart ${container} with '${MODEL_PROFILE}'? [y/N]: " ans
    case "$ans" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted."
      # Return, not exit: exiting here would run a caller's armed EXIT trap
      # (llama-cpp-run.sh) and remove the healthy server we were told to keep.
      return 11
      ;;
    esac
  fi
  docker compose "$@" up -d --force-recreate llama-server
}

# Usage: llama_wait_healthy CONTAINER LOGS_HINT
# Polls /health inside the container (no host port needed) for up to 5 min.
llama_wait_healthy() {
  local container="$1" logs_hint="$2" i
  echo -n "Waiting for ${container} to load the model"
  for ((i = 0; i < 150; i++)); do
    if docker exec "$container" curl -sf http://localhost:8080/health >/dev/null 2>&1; then
      echo
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]]; then
      echo
      echo "Error: ${container} exited. Last log lines:" >&2
      docker logs --tail 30 "$container" >&2 || true
      exit 1
    fi
    echo -n "."
    sleep 2
  done
  echo
  echo "Error: ${container} not healthy after 5 minutes. Check '${logs_hint}'." >&2
  exit 1
}
