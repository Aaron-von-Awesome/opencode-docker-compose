# OpenCode V2 + Docker Compose + Docker Model Runner

A local development environment for OpenCode V2, fully contained in a Docker container. Provides a linuxserver.io-style `abc` user with runtime UID/GID remapping, host-side persistent config and state, and a single-command launch.

## Prerequisites

- Docker with the Compose plugin (`docker compose ...`)

## First-time setup

Clone the repo, then run the initializer script located in the repository:

```bash
./opencode-init.sh
```

`opencode-init.sh` does two things:

1. **Copies the project artifacts to `${HOME}/OpenCode/`** — `Dockerfile`, `docker-compose.yaml`, `entrypoint.sh`, `opencode-run.sh`, the three `.jsonc` templates, the `models/` overlay directory, and anything else in the repo root _except_ `README.md`, anything matching `.git*`, and the initialize script itself. For each file that already exists at the destination you'll be prompted to overwrite (default: skip).
2. **Adds the `opencode` alias to `~/.bashrc`** (if not already present) so you can launch from any directory:
   ```bash
   alias opencode='${HOME}/OpenCode/opencode-run.sh'
   ```
   After it finishes, run `source ~/.bashrc` or open a new shell to activate.

Safe to re-run — overwrite prompts and the alias-presence check keep it idempotent.

## Quick start

```bash
# Local model via Docker Model Runner:
./opencode-run.sh --model gpt120b [/path/to/your/project]

# Cloud / third-party provider configured in opencode.jsonc:
./opencode-run.sh [/path/to/your/project]
```

If no path is given, the current directory is used. If no `--model` is given, OpenCode launches without binding any local model — use this when your `opencode.jsonc` is configured for a cloud / third-party provider (see <https://opencode.ai/v2/docs/models/>).

The script:

1. Parses `--model` and the optional workspace path. When `--model` is supplied, validates the overlay exists under `models/`.
2. If a local model is requested, checks `docker model ps`. If any model **other than** the requested one is currently loaded, prints the list, prompts the user to confirm, and on confirmation runs `docker model unload <id>` for each of the other models before launching. Default response is to abort.
3. Computes a `DIRECTORY_ID` to namespace the local image tag (`local/${DIRECTORY_ID}/opencode:latest-stable`).
4. Bootstraps host-side directories under `${HOME}/OpenCode/...` (see below).
5. On first run, prompts for git identity and generates an SSH key (`id_opencode`).
6. Builds the image if needed, then runs `docker compose -f docker-compose.yaml [-f models/<shortname>.yaml] run --rm opencode`.

## Convenience: shell alias

`opencode-init.sh` already adds the `opencode` alias to `~/.bashrc` on first-time setup, so you usually don't need to touch this. If you skipped initialization or want to install the alias manually:

```bash
echo "alias opencode='\${HOME}/OpenCode/opencode-run.sh'" >> ~/.bashrc
source ~/.bashrc
```

(Note the escaped `\${HOME}` — that keeps the variable as-is in the alias definition so it's expanded _at run time_, not when the alias is written.)

Once the alias is in place, every form of the launcher works the same way — arguments are passed through unchanged:

```bash
opencode                                  # cloud mode, current directory as workspace
opencode --model gpt120b                  # local model, current directory
opencode /path/to/your/project            # cloud mode, given project as workspace
opencode --model gpt120b /path/to/project # local model, given project
opencode --help                           # show usage and available overlays
```

Because the alias is a literal text substitution, anything you'd put on the `./opencode-run.sh` command line works identically with `opencode`. The script's own argument parser handles flag/path ordering.

## Model selection

Two modes:

### Local model (via Docker Model Runner)

Only **one** local model is bound to the service per launch — Docker Model Runner has no documented way to cap concurrent loads, so we control it at the compose level by merging in exactly one overlay file at runtime.

```bash
./opencode-run.sh --model gpt120b     # ai/gpt-oss:120b-f16
./opencode-run.sh --model qwen3635b   # ai/qwen3.6:35b-a3b-mtp-q8_0
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

> **Important:** The default `opencode.jsonc` template ships with a
> `"provider"` block pre-configured for local-model mode. If you use
> `opencode` **without** `--model` (cloud mode), remove the entire
> `"provider": { … }` section. See
> <https://opencode.ai/v2/docs/models/> for provider configuration.

### How it interacts with `opencode.jsonc` (local-model mode)

`opencode.jsonc` defines a single generic provider named `active` that reads three env vars: `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`, and `ACTIVE_MODEL_DISPLAY_NAME`. Every local-model overlay populates those three vars. The result:

- OpenCode's picker shows exactly one model — the one you launched with — under whatever friendly name the overlay set.
- No "selecting the wrong model" failure mode: the picker only ever offers the bound model.
- Adding a new local model = one overlay file. `opencode.jsonc` never changes.

To add a local model, mirror an existing overlay (e.g. `models/gpt120b.yaml`):

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

For cloud-mode usage, remove the `"provider"` block from the default `opencode.jsonc` — see the warning in [Cloud / third-party provider](#cloud--third-party-provider) above.

## Workspace customization

You can customize the OpenCode service for specific projects by placing an `extra-compose.yaml` file in your workspace directory. This file is automatically detected and merged into the compose invocation, enabling per-project customizations like:

- Joining external Docker networks (e.g., a KiwiFS network)
- Adding custom volumes
- Setting environment variables
- Modifying the working directory

### How it works

1. Place an `extra-compose.yaml` file in your project directory
2. Run OpenCode with that directory as the workspace: `./opencode-run.sh /path/to/your/project`
3. The script detects the file, validates it, and merges it with the base configuration

### Validation

The `extra-compose.yaml` file is validated to ensure it only modifies the `opencode` service. This prevents accidentally adding new services to the compose project. The validation checks:

- Only the `opencode` service is defined under `services:`
- Additional services (e.g., `kiwifs`, `database`) are **not allowed**
- Any modifications to the `opencode` service are permitted (networks, volumes, environment, etc.)

### Examples

#### Joining an external network (KiwiFS scenario)

```yaml
services:
  opencode:
    networks:
      - kiwifs-net

networks:
  kiwifs-net:
    external: true
```

#### Multiple external networks

```yaml
services:
  opencode:
    networks:
      - kiwifs-net
      - database-net

networks:
  kiwifs-net:
    external: true
  database-net:
    external: true
```

#### Adding volumes and environment variables

```yaml
services:
  opencode:
    volumes:
      - ./data:/home/abc/workspace/data
      - ./config:/home/abc/workspace/config
    environment:
      CUSTOM_VAR: "value"
      API_KEY: "your-api-key"
    working_dir: "/home/abc/workspace/project"

networks:
  opencode-net:
    external: true
```

#### Combining network and volume customizations

```yaml
services:
  opencode:
    networks:
      - kiwifs-net
    volumes:
      - ./gtd-kiwi-fs:/home/abc/workspace/gtd-kiwi-fs
    environment:
      KIWIFS_URL: "http://kiwifs:3333"

networks:
  kiwifs-net:
    external: true
```

### Output

When an `extra-compose.yaml` file is detected, the script displays its path in the startup output:

```
Starting OpenCode in container...
  Workspace: /home/abc/KiwiFS-Implementation/PoC
  Config:    /home/abc/OpenCode/dot-config/
  Model:     (none — cloud/third-party mode; see opencode.jsonc)
  User:      abc (PUID=1000, PGID=1000)
---------------------------------------------------
  Script Directory:    /home/abc/opencode-docker-compose
  Extra Compose: /home/abc/KiwiFS-Implementation/PoC/extra-compose.yaml
---------------------------------------------------
```

## Host-side layout (`${HOME}/OpenCode/...`)

| Path                       | Maps to in container | Purpose                                                                                                                                                                                                      |
| -------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dot-config/`              | `~/.config/`         | Everything OpenCode reads from its XDG default location — skills, agents, commands, themes, plugins (`~/.config/opencode/*`), plus the seeded `opencode.jsonc` and `cli.json` (see "Config seeding" below). |
| `dot-local/`               | `~/.local/`          | DB, auth, sessions, prompt history, model selection                                                                                                                                                          |
| `dot-cache/`               | `~/.cache/`          | Download/build cache, agent binaries                                                                                                                                                                         |
| `dot-npm/`                 | `~/.npm/`            | Plugin/skill dependency cache                                                                                                                                                                                |
| `dot-ssh/`                 | `~/.ssh/`            | SSH keys (generated on first run)                                                                                                                                                                            |
| `dot-gitconfig/.gitconfig` | `~/.gitconfig`       | Git identity (prompted on first run)                                                                                                                                                                         |

### Config seeding

`opencode.jsonc.template` and `cli.jsonc.template` are placed alongside `opencode-run.sh` at the script root by `opencode-init.sh`. On every launch, `opencode-run.sh` **moves** whichever of them exist into `${HOME}/OpenCode/dot-config/opencode/` — stripping the `.template` suffix so each becomes `opencode.jsonc` and `cli.json` — which is bind-mounted to `~/.config/opencode/` inside the container, the XDG default OpenCode reads from. The compose file no longer sets `OPENCODE_CONFIG` or `OPENCODE_TUI_CONFIG`; OpenCode just picks them up from the default path.

The script root is a **transient handoff slot**, not a permanent home for the config files:

- First launch after `opencode-init.sh`: the three template files exist at the script root → `opencode-run.sh` moves them into `dot-config/opencode/`. If the destination files already exist, they are first copied to a timestamped backup (e.g. `20260716-143022_opencode.jsonc.backup`) before being overwritten.
- Subsequent launches: the script root is empty → the move step is silently skipped, and OpenCode continues reading the previously-seeded files from `dot-config/opencode/`.
- If you never run `opencode-init.sh` (or you delete the source files), the move step is skipped on every launch and OpenCode falls back to whatever defaults it writes itself.

**To push updated config:** edit the canonical templates in your cloned repo, re-run `opencode-init.sh` (which re-copies them into the script root, prompting on overwrite), then launch with `opencode` — the move step picks them up. Any existing config at the destination is backed up automatically.

Edit config files on the host; changes take effect on the next container start. Auth, sessions, and DB persist across image rebuilds.

## Files

- `opencode-init.sh` — Host-side first-time-setup script. Copies the project tree to `${HOME}/OpenCode/` (excluding `README.md`, `.git*`, and itself), prompts before overwriting existing files, and installs the `opencode` alias in `~/.bashrc` if not already present. Idempotent; safe to re-run.
- `Dockerfile` — Ubuntu 26.04 base. Installs Node + uv + OpenCode toolchain; copies the OpenCode binary to `/usr/local/bin/` so it survives any bind mount under `/home/abc`. Hardening borrowed from linuxserver.io: `userdel ubuntu` removes the default UID-1000 user that ships with 26.04 (eliminates a PUID collision), `locales` is installed and `en_US.UTF-8` generated to prevent TUI/encoding glitches, and the `abc` user is created via `useradd -u 911 -U` (matching group auto-created; GID is remapped at runtime).
- `entrypoint.sh` — Remaps `abc` UID/GID to host `PUID`/`PGID`, then drops privileges via `gosu`.
- `opencode-run.sh` — Host-side launcher. Parses `--model`, validates overlays, runs the Model Runner pre-flight (unloads any conflicting models), bootstraps host directories and git/SSH identity, then invokes compose with the selected model overlay. Detects and merges `extra-compose.yaml` from workspace directory for per-project OpenCode service customization (validated to allow only `opencode` service modifications).
- `docker-compose.yaml` — Base service definition: volume mounts, env-var-driven config paths. **No model bindings** — those live in `models/` overlays.
- `models/*.yaml` — One overlay per model. Each adds a single `llm_active` binding (env vars `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`) plus an `environment:` block setting `ACTIVE_MODEL_DISPLAY_NAME` for the picker label. Selected at runtime via `--model`.
- `opencode.jsonc.template`, `cli.jsonc.template` — Canonical config templates at the script root. Moved into `${HOME}/OpenCode/dot-config/opencode/` on every launch (`.template` suffix is stripped, producing `opencode.jsonc` and `cli.json`), which the container sees at `~/.config/opencode/` (the XDG default). Edit these to change the config; delete them to fall back to OpenCode-generated defaults.

## Troubleshooting: "Background service failed to start"

**Symptom:** `opencode-run.sh` exits with `Error: Background service failed to start`. `opencode --standalone` fails the same way.

**Cause:** On startup, OpenCode 2.0.20 runs database migration `20260812213948_worktree`. It fails with `FOREIGN KEY constraint failed` because the persisted DB has orphaned `project_directory` rows, so the server exits on every launch. The log (`~/OpenCode/dot-local/share/opencode/log/opencode.log`) shows `database migration failed`.

**Fix:** `cd` into the data directory, back up the DB, delete the orphaned rows, then relaunch:

```bash
cd ~/OpenCode/dot-local/share/opencode/
cp opencode.db opencode.db.bak
sqlite3 opencode.db "DELETE FROM project_directory WHERE project_id NOT IN (SELECT id FROM project);"
```

If that doesn't work, move `opencode.db` aside so OpenCode creates a fresh one. You lose existing sessions.
