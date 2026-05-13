# OpenCode + Docker Compose + Docker Model Runner

A local development environment for OpenCode, fully contained in a Docker container. Provides a linuxserver.io-style `abc` user with runtime UID/GID remapping, host-side persistent config and state, and a single-command launch.

## Prerequisites

- Docker with the Compose plugin (`docker compose ...`)

## Quick start

```bash
./opencode-run.sh [--model SHORTNAME] [/path/to/your/project]
```

If no path is given, the current directory is used. If no model is given, the smallest model (`gpt20`) is loaded.

The script:

1. Parses `--model` and the optional workspace path; validates the model overlay exists under `models/`.
2. Computes a `DIRECTORY_ID` to namespace the local image tag (`local/${DIRECTORY_ID}/opencode:latest-stable`).
3. Bootstraps host-side directories under `${HOME}/OpenCode/...` (see below).
4. On first run, prompts for git identity and generates an SSH key (`id_opencode`).
5. Builds the image if needed, then runs `docker compose -f docker-compose.yaml -f models/<shortname>.yaml run --rm opencode`.

## Model selection

Only **one** model is bound to the service per launch — Docker Model Runner has no documented way to cap concurrent loads, so we control it at the compose level by merging in exactly one overlay file at runtime.

```bash
./opencode-run.sh --model gpt20    # default: ai/gpt-oss:20B-F16
./opencode-run.sh --model gpt120   # huggingface.co/unsloth/gpt-oss-120b-gguf:F16
./opencode-run.sh --model gemma31  # ai/gemma4:31B
./opencode-run.sh --model mistral  # ai/mistral-small4 (with sampler runtime_flags)
```

Each shortname maps to the file `models/<shortname>.yaml`. To add a new model, drop a new overlay file in `models/` — no script edits needed. `./opencode-run.sh --help` lists what's available.

### How it interacts with `opencode.jsonc`

`opencode.jsonc` defines a single generic provider named `active` that reads three env vars: `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`, and `ACTIVE_MODEL_DISPLAY_NAME`. Every overlay populates those three vars. The result:

- OpenCode's picker shows exactly one model — the one you launched with — under whatever friendly name the overlay set.
- No "selecting the wrong model" failure mode: the picker only ever offers the bound model.
- Adding a new model = one overlay file. `opencode.jsonc` never changes.

To add a model, mirror an existing overlay (e.g. `models/gpt20.yaml`):

```yaml
services:
  opencode:
    models:
      llm_active:
        endpoint_var: ACTIVE_MODEL_URL
        model_var: ACTIVE_MODEL_NAME
    environment:
      ACTIVE_MODEL_DISPLAY_NAME: "My New Model"

models:
  llm_active:
    model: <docker-model-runner-identifier>
    # runtime_flags: [...]  # optional per-model sampler/inference flags
```

## Host-side layout (`${HOME}/OpenCode/...`)

| Path | Maps to in container | Purpose |
|------|----------------------|---------|
| `dot-opencode/` | `OPENCODE_CONFIG_DIR` | Skills, agents, commands, themes, plugins |
| `dot-opencode-json/opencode.jsonc` | `OPENCODE_CONFIG` | Global OpenCode config |
| `dot-opencode-json/tui.jsonc` | `OPENCODE_TUI_CONFIG` | TUI config |
| `dot-local/` | `~/.local/` | DB, auth, sessions, prompt history, model selection |
| `dot-cache/` | `~/.cache/` | Download/build cache, agent binaries |
| `dot-npm/` | `~/.npm/` | Plugin/skill dependency cache |
| `dot-ssh/` | `~/.ssh/` | SSH keys (generated on first run) |
| `dot-gitconfig/.gitconfig` | `~/.gitconfig` | Git identity (prompted on first run) |

Edit config files on the host; changes take effect on the next container start. Auth, sessions, and DB persist across image rebuilds.

## Files

- `Dockerfile` — Ubuntu 24.04 base; installs OpenCode via the official installer, then copies the binary to `/usr/local/bin/` so it survives bind mounts.
- `entrypoint.sh` — Remaps `abc` UID/GID to host `PUID`/`PGID`, then drops privileges via `gosu`.
- `opencode-run.sh` — Host-side launcher (arg parsing, UID/GID export, host-dir bootstrap, git/SSH bootstrap, compose invocation with the selected model overlay).
- `docker-compose.yaml` — Base service definition: volume mounts, env-var-driven config paths. **No model bindings** — those live in `models/` overlays.
- `models/*.yaml` — One overlay per model. Each defines a single `models:` binding and the corresponding top-level model spec. Selected at runtime via `--model`.
