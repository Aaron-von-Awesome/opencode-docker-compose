#!/usr/bin/env bash
# Usage: ./llama-cpp-run.sh --model SHORTNAME | --stop | --logs | --help
# Runs llama-server on its own, in the background, for OpenCode instances on
# this machine or the LAN to share (opencode-init.sh backend "remote").
# Reuses docker-compose.llama-cpp.yaml and models/cpp/<shortname>.yaml, plus
# docker-compose.llama-cpp-standalone.yaml for the published port.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="llama-cpp-standalone"
CONTAINER="llama-server-standalone"

# shellcheck source=llama-cpp-lib.sh
source "${SCRIPT_DIR}/llama-cpp-lib.sh"

# All compose calls are project-relative (--stop too); cd before first use.
cd "$SCRIPT_DIR"

usage() {
  cat <<EOF
Usage: $(basename "$0") --model SHORTNAME | --stop | --logs | --help

  --model, -m SHORTNAME   Start (or restart) the standalone llama-server in
                          the background. Available models (models/cpp/):
$(list_model_overlays cpp "                          ")
  --stop                  Stop and remove it.
  --logs                  Follow its logs (Ctrl-C to stop following).
  --help, -h              Show this help and exit.

Environment:
  LLAMA_PORT              Host port to publish (default: 8080).
  LLAMA_BIND              Host address to bind (default: 0.0.0.0, all
                          interfaces). 127.0.0.1 is unreachable from
                          OpenCode containers via host.docker.internal.
  LLAMA_API_KEY           Optional API key clients must send. Unset or empty
                          means no key.
  OPENCODE_GGUF_DIR       Host folder holding the GGUF files
                          (default: /mnt/storage/llama-cpp/models).
EOF
}

MODEL_PROFILE=""
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --model | -m)
    [[ $# -ge 2 ]] || {
      echo "Error: --model requires an argument" >&2
      exit 1
    }
    MODEL_PROFILE="$2"
    ACTION="start"
    shift 2
    ;;
  --stop) ACTION="stop"; shift ;;
  --logs) ACTION="logs"; shift ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    echo "Error: unknown argument $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

case "$ACTION" in
stop)
  docker compose -p "$PROJECT" -f docker-compose.llama-cpp.yaml -f docker-compose.llama-cpp-standalone.yaml down --remove-orphans
  exit 0
  ;;
logs)
  exec docker logs -f "$CONTAINER"
  ;;
start) ;;
*)
  usage >&2
  exit 1
  ;;
esac

MODEL_OVERLAY="${SCRIPT_DIR}/models/cpp/${MODEL_PROFILE}.yaml"
if [[ ! -f "$MODEL_OVERLAY" ]]; then
  echo "Error: no overlay for model '${MODEL_PROFILE}' at ${MODEL_OVERLAY}" >&2
  echo "Available models:" >&2
  list_model_overlays cpp "  " >&2
  exit 1
fi

llama_preflight "$MODEL_OVERLAY"
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
  export LLAMA_ARG_API_KEY="$LLAMA_API_KEY"
fi

COMPOSE_ARGS=(-p "$PROJECT" -f docker-compose.llama-cpp.yaml -f docker-compose.llama-cpp-standalone.yaml -f "models/cpp/${MODEL_PROFILE}.yaml")

warning="Connected OpenCode sessions will lose their model until it's back up."
# The key lives only in the shell that started the server; a restart from a
# shell without it would silently open the port.
running_env="$(docker inspect -f '{{if .State.Running}}{{range .Config.Env}}{{println .}}{{end}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
if [[ -z "${LLAMA_API_KEY:-}" ]] && grep -q '^LLAMA_ARG_API_KEY=.' <<<"$running_env"; then
  warning+=$'\n'"WARNING: the running server requires an API key, but LLAMA_API_KEY is not set here."
  warning+=$'\n'"Restarting would leave port ${LLAMA_PORT:-8080} open to anyone who can reach it. Answer N and re-run with LLAMA_API_KEY=... to keep the key."
fi

# Armed before the start so a skipped health wait can't leave the server
# crash-looping under restart: unless-stopped; cleared on the paths where a
# healthy server must survive (reused, or the user declined the restart).
trap 'echo "Removing the failed server." >&2; docker compose -p "$PROJECT" -f docker-compose.llama-cpp.yaml -f docker-compose.llama-cpp-standalone.yaml down --remove-orphans' EXIT
rc=0
llama_start_or_reuse "$CONTAINER" "$warning" "${COMPOSE_ARGS[@]}" || rc=$?
case $rc in
0) ;;
10) trap - EXIT ;;
11) trap - EXIT; exit 1 ;;
*) exit "$rc" ;; # start failed; the EXIT trap removes the crash-looped container
esac
llama_wait_healthy "$CONTAINER" "$(basename "$0") --logs"
trap - EXIT

echo "Standalone llama-server is serving '${MODEL_PROFILE}' on ${LLAMA_BIND:-0.0.0.0}:${LLAMA_PORT:-8080}."
echo "  Same machine: http://host.docker.internal:${LLAMA_PORT:-8080}/v1"
echo "  LAN:          http://$(hostname -I 2>/dev/null | awk '{print $1}'):${LLAMA_PORT:-8080}/v1"
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
  echo "  API key:      required"
else
  echo "  API key:      none — anyone who can reach the port can use it (set LLAMA_API_KEY)"
fi
