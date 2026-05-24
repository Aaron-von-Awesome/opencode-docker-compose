# OpenCode + Docker Compose + Docker Model Runner

A local development environment for OpenCode, fully contained in a Docker container. Provides a linuxserver.io-style `abc` user with runtime UID/GID remapping, host-side persistent config and state, and a single-command launch.

## Prerequisites

- Docker with the Compose plugin (`docker compose ...`)

## Quick start

```bash
# Local model via Docker Model Runner:
./opencode-run.sh --model gpt20 [/path/to/your/project]

# Cloud / third-party provider configured in opencode.jsonc:
./opencode-run.sh [/path/to/your/project]
```

If no path is given, the current directory is used. If no `--model` is given, OpenCode launches without binding any local model — use this when your `opencode.jsonc` is configured for a cloud / third-party provider (see <https://opencode.ai/docs/models/>).

The script:

1. Parses `--model` and the optional workspace path. When `--model` is supplied, validates the overlay exists under `models/`.
2. If a local model is requested, checks `docker model ps`. If any model **other than** the requested one is currently loaded, prints the list, prompts the user to confirm, and on confirmation runs `docker model unload <id>` for each of the other models before launching. Default response is to abort.
3. Computes a `DIRECTORY_ID` to namespace the local image tag (`local/${DIRECTORY_ID}/opencode:latest-stable`).
4. Bootstraps host-side directories under `${HOME}/OpenCode/...` (see below).
5. On first run, prompts for git identity and generates an SSH key (`id_opencode`).
6. Builds the image if needed, then runs `docker compose -f docker-compose.yaml [-f models/<shortname>.yaml] run --rm opencode`.

## Convenience: shell alias

Add an alias to your `~/.bashrc` so you can launch from any directory without typing the full script path. Assuming the launcher lives at `${HOME}/OpenCode/opencode-run.sh`:

```bash
echo "alias opencode='\${HOME}/OpenCode/opencode-run.sh'" >> ~/.bashrc
source ~/.bashrc
```

(Note the escaped `\${HOME}` — that keeps the variable as-is in the alias definition so it's expanded *at run time*, not when the alias is written.)

Once the alias is in place, every form of the launcher works the same way — arguments are passed through unchanged:

```bash
opencode                                  # cloud mode, current directory as workspace
opencode --model gpt20                    # local model, current directory
opencode /path/to/your/project            # cloud mode, given project as workspace
opencode --model gpt120 /path/to/project  # local model, given project
opencode --help                           # show usage and available overlays
```

Because the alias is a literal text substitution, anything you'd put on the `./opencode-run.sh` command line works identically with `opencode`. The script's own argument parser handles flag/path ordering.

## Model selection

Two modes:

### Local model (via Docker Model Runner)

Only **one** local model is bound to the service per launch — Docker Model Runner has no documented way to cap concurrent loads, so we control it at the compose level by merging in exactly one overlay file at runtime.

```bash
./opencode-run.sh --model gpt20    # ai/gpt-oss:20B-F16
./opencode-run.sh --model gpt120   # huggingface.co/unsloth/gpt-oss-120b-gguf:F16
./opencode-run.sh --model gemma31  # ai/gemma4:31B
./opencode-run.sh --model devstral # ai/devstral-small-2
```

Each shortname maps to the file `models/<shortname>.yaml`. To add a new model, drop a new overlay file in `models/` — no script edits needed. `./opencode-run.sh --help` lists what's available.

#### Pre-flight: unload conflicting models

Before launch, the script consults `docker model ps`. If any model **other than** the requested one is currently loaded, you'll see a prompt listing the offending models. Confirming runs `docker model unload <id>` for each of them so Docker Model Runner only has the requested model resident when OpenCode starts. The unload preserves the model on disk — it just frees memory — so the next launch of that model doesn't re-download anything.

#### Note: `docker-model-runner` reports `(unhealthy)` — ignore it

The `docker/model-runner` image ships with a `curl -f /health` healthcheck and no `start_period`. The first ~2 minutes of any large F16/Q4 model load show the container as `(unhealthy)` because the inference server hasn't bound port 8080 yet, and the failures accumulate against the default retry budget. This is cosmetic only — inference works regardless. Several runtime workarounds were attempted (`docker update --health-start-period`, `--no-healthcheck`, and `--health-cmd "/bin/true"`); none stuck, because the DMR plugin reasserts the image's declared healthcheck on each model-binding cycle. Treat the `(unhealthy)` annotation in `docker ps` as expected noise.

### Cloud / third-party provider

Omit `--model` entirely:

```bash
./opencode-run.sh [/path/to/your/project]
```

The base compose file has no model bindings, so Docker Model Runner is bypassed and OpenCode uses whatever provider you've configured in `opencode.jsonc`. Provider setup (API keys, model identifiers, etc.) is OpenCode's concern — see <https://opencode.ai/docs/models/>.

### How it interacts with `opencode.jsonc` (local-model mode)

`opencode.jsonc` defines a single generic provider named `active` that reads three env vars: `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`, and `ACTIVE_MODEL_DISPLAY_NAME`. Every local-model overlay populates those three vars. The result:

- OpenCode's picker shows exactly one model — the one you launched with — under whatever friendly name the overlay set.
- No "selecting the wrong model" failure mode: the picker only ever offers the bound model.
- Adding a new local model = one overlay file. `opencode.jsonc` never changes.

To add a local model, mirror an existing overlay (e.g. `models/gpt20.yaml`):

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

For cloud-mode usage, you'll want a different `opencode.jsonc` — one that declares your cloud provider(s) instead of (or in addition to) the `active` block. The active block fails gracefully in cloud mode (its env vars are empty), but listing it in `enabled_providers` will surface an unusable entry in the picker, so you'll likely want to drop or swap that block when you're using a cloud provider.

## Host-side layout (`${HOME}/OpenCode/...`)

| Path                               | Maps to in container  | Purpose                                                              |
| ---------------------------------- | --------------------- | -------------------------------------------------------------------- |
| `dot-config/`                      | `~/.config/`          | Skills, agents, commands, themes, plugins (under `~/.config/opencode/`) |
| `dot-opencode-json/opencode.jsonc` | `OPENCODE_CONFIG`     | Global OpenCode config                                               |
| `dot-opencode-json/tui.jsonc`      | `OPENCODE_TUI_CONFIG` | TUI config                                                           |
| `dot-local/`                       | `~/.local/`           | DB, auth, sessions, prompt history, model selection                  |
| `dot-cache/`                       | `~/.cache/`           | Download/build cache, agent binaries                                 |
| `dot-npm/`                         | `~/.npm/`             | Plugin/skill dependency cache                                        |
| `dot-ssh/`                         | `~/.ssh/`             | SSH keys (generated on first run)                                    |
| `dot-gitconfig/.gitconfig`         | `~/.gitconfig`        | Git identity (prompted on first run)                                 |

Edit config files on the host; changes take effect on the next container start. Auth, sessions, and DB persist across image rebuilds.

## Files

- `Dockerfile` — Ubuntu 24.04 base. Installs Node + uv + OpenCode toolchain; copies the OpenCode binary to `/usr/local/bin/` so it survives any bind mount under `/home/abc`. Hardening borrowed from linuxserver.io: `userdel ubuntu` removes the default UID-1000 user that ships with 24.04 (eliminates a PUID collision), `locales` is installed and `en_US.UTF-8` generated to prevent TUI/encoding glitches, and the `abc` user is created via `useradd -u 911 -U` (matching group auto-created; GID is remapped at runtime).
- `entrypoint.sh` — Remaps `abc` UID/GID to host `PUID`/`PGID`, then drops privileges via `gosu`.
- `opencode-run.sh` — Host-side launcher. Parses `--model`, validates overlays, runs the Model Runner pre-flight (unloads any conflicting models), bootstraps host directories and git/SSH identity, then invokes compose with the selected model overlay.
- `docker-compose.yaml` — Base service definition: volume mounts, env-var-driven config paths. **No model bindings** — those live in `models/` overlays.
- `models/*.yaml` — One overlay per model. Each adds a single `llm_active` binding (env vars `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`) plus an `environment:` block setting `ACTIVE_MODEL_DISPLAY_NAME` for the picker label. Selected at runtime via `--model`.
- `dot-opencode-json/opencode.jsonc`, `dot-opencode-json/tui.jsonc` — Template configs. The live versions are bind-mounted from `${HOME}/OpenCode/dot-opencode-json/`; edit those, not these.
