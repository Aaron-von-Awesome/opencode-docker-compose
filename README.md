# OpenCode V2 + Docker Compose + llama.cpp / Docker Model Runner

A local development environment for OpenCode V2, fully contained in a Docker container, with optional local models served by a llama.cpp (`llama-server`) container (default) or Docker Model Runner. Provides a linuxserver.io-style `abc` user with runtime UID/GID remapping, host-side persistent config and state, and a single-command launch.

## Prerequisites

- Docker with the Compose plugin (`docker compose ...`)
- Local mode with llama.cpp (default): an AMD GPU with ROCm (`/dev/kfd`, `/dev/dri`) and the GGUF files in `/mnt/storage/llama-cpp/models` (override with `OPENCODE_GGUF_DIR`)
- Local mode with Docker Model Runner: Docker Model Runner enabled (`docker model ...`)

## First-time setup

Clone the repo, then run the initializer script located in the repository:

```bash
./opencode-init.sh
```

`opencode-init.sh` does three things:

1. **Copies the project artifacts to `${HOME}/OpenCode/`** — `Dockerfile`, `docker-compose.yaml`, `docker-compose.llama-cpp.yaml`, `entrypoint.sh`, `opencode-run.sh`, `cli.json.template`, the `models/` overlay directory, and anything else in the repo root _except_ `README.md`, `AGENTS.md`, `LICENSE`, anything matching `.git*`, the two `opencode.jsonc.*.template` files, and the initialize script itself. For each file that already exists at the destination you'll be prompted to overwrite (default: skip).
2. **Prompts for a configuration type** — you choose `[c] Cloud` (third-party provider) or `[l] Local`. The matching template is deployed as `opencode.jsonc.template`. Your choice is saved to `${HOME}/OpenCode/.config-mode`, so re-runs skip the prompt. Delete `.config-mode` and re-run to switch.
   - **Local only — prompts for a backend:** `[c] llama.cpp` (default, press Enter) or `[d] Docker Model Runner`. Saved to `${HOME}/OpenCode/.local-backend` (`cpp` or `dmr`); delete it and re-run to switch. There is no per-launch override.
3. **Adds the `opencode` alias to `~/.bashrc`** (if not already present) so you can launch from any directory:
   ```bash
   alias opencode='${HOME}/OpenCode/opencode-run.sh'
   ```
   After it finishes, run `source ~/.bashrc` or open a new shell to activate.

Safe to re-run — overwrite prompts and the alias-presence check keep it idempotent.

## Quick start

```bash
# Local model (backend chosen at init: llama.cpp or Docker Model Runner):
./opencode-run.sh --model ornith15 [/path/to/your/project]

# Cloud / third-party provider configured in opencode.jsonc:
./opencode-run.sh [/path/to/your/project]
```

If no path is given, the current directory is used. If no `--model` is given, OpenCode launches without binding any local model — use this when your `opencode.jsonc` is configured for a cloud / third-party provider (see <https://opencode.ai/v2/docs/models/>).

The script:

1. Parses `--model` and the optional workspace path. When `--model` is supplied, validates the overlay exists under `models/<backend>/`. llama.cpp: checks the GGUF exists. DMR: if other models are loaded (`docker model ps`), prompts to unload them.
2. Computes a `DIRECTORY_ID` to namespace the local image tag (`local/${DIRECTORY_ID}/opencode:latest-stable`).
3. Bootstraps host-side directories under `${HOME}/OpenCode/...` and seeds config (see below).
4. On first run, prompts for git identity and generates an SSH key (`id_opencode`).
5. If the workspace has an `extra-compose.yaml`, checks it adds no services (see [Workspace customization](#workspace-customization)).
6. llama.cpp only: starts or reuses `llama-server` and waits for it to be healthy (see [llama-server lifecycle](#llama-server-lifecycle)).
7. Builds the image if needed, then runs `docker compose -f docker-compose.yaml [-f docker-compose.llama-cpp.yaml] [-f models/<backend>/<shortname>.yaml] [-f extra-compose.yaml] run --rm opencode`.

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
opencode --model ornith15                 # local model, current directory
opencode /path/to/your/project            # cloud mode, given project as workspace
opencode --model ornith15 /path/to/project # local model, given project
opencode --help                           # show usage and available overlays
```

Because the alias is a literal text substitution, anything you'd put on the `./opencode-run.sh` command line works identically with `opencode`. The script's own argument parser handles flag/path ordering.

## Model selection

Two modes:

### Local model

The backend is chosen once in `opencode-init.sh` and saved to `~/OpenCode/.local-backend`. Overlays live in `models/<backend>/`, and `--help` lists only the overlays for the saved backend.

| Backend                  | `.local-backend` | Overlays       |
| ------------------------ | ---------------- | -------------- |
| llama.cpp (default)      | `cpp`            | `models/cpp/`  |
| Docker Model Runner      | `dmr`            | `models/dmr/`  |

#### llama.cpp (default)

One `llama-server` container (ROCm image) serves exactly one model at a time. It is defined in `docker-compose.llama-cpp.yaml` and merged in, with one overlay, only when `--model` is given.

| Shortname    | Display name       | GGUF                            |
| ------------ | ------------------ | ------------------------------- |
| `ornith15`   | Ornith 1.5 A3B 35B | `Ornith-1.5-35B-Q4_K_M.gguf`    |
| `qwen3827b`  | Qwen3.8 27B        | `Qwen3.8-27B-UD-Q4_K_XL.gguf`   |
| `glm47flash` | GLM 4.7 Flash      | `GLM-4.7-Flash-Q4_K_M.gguf`     |

```bash
./opencode-run.sh --model qwen3827b
```

Each shortname maps to `models/cpp/<shortname>.yaml`. GGUF files are **not** downloaded; put them in `/mnt/storage/llama-cpp/models` (or set `OPENCODE_GGUF_DIR`). The host folder is always mounted read-only at `/mnt/storage/llama-cpp/models` in the container, so overlays use that path. A missing file aborts the launch.

##### The llama.cpp container

Defined in `docker-compose.llama-cpp.yaml`, in the same compose project as OpenCode:

- **Image:** `ghcr.io/ggml-org/llama.cpp:server-rocm` (AMD GPUs only).
- **Name:** fixed `container_name: llama-server`, labeled `opencode.model=<shortname>` so the launcher can tell which model is loaded.
- **GPU:** `/dev/kfd` and `/dev/dri` passed through; the host's `video` and `render` GIDs are looked up with `getent` (fallback 44 / 992).
- **Models:** `${OPENCODE_GGUF_DIR}` mounted read-only at `/mnt/storage/llama-cpp/models`.
- **Shared flags:** set via `LLAMA_ARG_*` env vars — host `0.0.0.0`, port `8080`, `-ngl 999`, `--flash-attn on`, and `--alias <shortname>`. Per-model flags come from the overlay's `command:`.
- **Network:** `opencode-net` only (see below).
- **Logs:** `docker logs -f llama-server`. If it exits during startup, the launcher prints the last 30 log lines.

##### llama-server lifecycle

- **Not running:** started with the requested model; the launcher polls `/health` via `docker exec` (up to 5 min).
- **Running the same model with the same config:** reused. If the overlay changed since it started (Compose config hash differs), you get the restart prompt.
- **Running a different model:** you're warned (including how many other sessions use it) and asked before it restarts. Default is abort.
- **On exit:** if no other llama.cpp OpenCode session is running, `llama-server` is stopped and removed; otherwise it keeps running. Cloud-mode sessions don't count. An `EXIT` trap runs this check, so it also fires on Ctrl-C.

`llama-server` is reachable only on the Docker network (`http://llama-server:8080`); no host port is published. To reach it from the host, add a `ports:` entry (e.g. `- "8080:8080"`) under `llama-server`, either in `~/OpenCode/docker-compose.llama-cpp.yaml` (all projects; re-running init will offer to overwrite it) or in a project's `extra-compose.yaml`.

#### Docker Model Runner

Each overlay in `models/dmr/` adds a single `llm_active` binding, so DMR loads exactly one model per launch. DMR pulls the model itself.

| Shortname  | Display name       | DMR model                      |
| ---------- | ------------------ | ------------------------------ |
| `ornith15` | Ornith 1.5 A3B 35B | `ai/ornith-1.5:35b-a3b-q4_K_M` |

##### Pre-flight: unload conflicting models

Before launch, the script consults `docker model ps`. If any model **other than** the requested one is currently loaded, you'll see a prompt listing them. Confirming runs `docker model unload <id>` for each, so only the requested model is resident when OpenCode starts. The model stays on disk, so the next launch doesn't re-download it.

##### Note: `docker-model-runner` reports `(unhealthy)` — ignore it

The `docker/model-runner` image ships with a `curl -f /health` healthcheck and no `start_period`. The first ~2 minutes of a large model load show the container as `(unhealthy)` because the server hasn't bound port 8080 yet. This is cosmetic — inference works regardless. `docker update --health-*` workarounds don't stick, because the DMR plugin reasserts the image's healthcheck on each model-binding cycle.

### Cloud / third-party provider

Omit `--model` entirely:

```bash
./opencode-run.sh [/path/to/your/project]
```

Neither backend is started, and OpenCode uses whatever provider you've configured in `opencode.jsonc`. Provider setup (API keys, model identifiers, etc.) is OpenCode's concern — see <https://opencode.ai/v2/docs/models/>.

> **Important:** Cloud mode needs the cloud template (`opencode-go` provider,
> no local `active` provider). If you chose local at init, delete
> `~/OpenCode/.config-mode`, re-run `opencode-init.sh`, and pick cloud.

### How it interacts with `opencode.jsonc` (local-model mode)

`opencode.jsonc` defines a single generic provider named `active` that reads three env vars: `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`, and `ACTIVE_MODEL_DISPLAY_NAME`. With llama.cpp, `docker-compose.llama-cpp.yaml` sets the URL (`http://llama-server:8080/v1`) and name (the shortname, also used as `--alias`). With DMR, the overlay's `models.llm_active` binding (`endpoint_var` / `model_var`) makes DMR inject them. Each overlay sets the display name. The result:

- OpenCode's picker shows exactly one model — the one you launched with — under whatever friendly name the overlay set.
- No "selecting the wrong model" failure mode: the picker only ever offers the bound model.
- Adding a new local model = one overlay file. `opencode.jsonc` never changes.

To add a llama.cpp model, mirror `models/cpp/ornith15.yaml`:

```yaml
services:
  opencode:
    environment:
      ACTIVE_MODEL_DISPLAY_NAME: "My New Model"

  llama-server:
    environment:
      LLAMA_ARG_MODEL: "/mnt/storage/llama-cpp/models/My-New-Model-Q4_K_M.gguf"
    command: # optional per-model llama-server flags
      - "--ctx-size"
      - "65536"
```

Shared flags (`-ngl 999`, `--flash-attn on`, host/port, alias) are set via `LLAMA_ARG_*` env vars in `docker-compose.llama-cpp.yaml`.

To add a Docker Model Runner model, mirror `models/dmr/ornith15.yaml`:

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
    # runtime_flags: [...]  # optional per-model flags
```

The same shortname can exist in both folders; only the one for the saved backend is used.

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

The launcher runs `docker compose config --services` with and without `extra-compose.yaml` and compares the lists:

- New services (e.g., `kiwifs`, `database`) are **not allowed**
- Changes to existing services are permitted: `opencode` (networks, volumes, environment, etc.), and `llama-server` with the llama.cpp backend (e.g. a `ports:` entry)

### Paths in `extra-compose.yaml`

- **Relative paths** like `./data` resolve against `~/OpenCode/`, the folder of the first compose file, not your project. Use absolute paths or `${HOME}` / `${WORKSPACE_DIR}`.
- **Your project** is mounted at `/home/abc/${OC_PROJECT_NAME}` (the folder's name), not `/home/abc/workspace`.

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
      - "${HOME}/datasets:/home/abc/datasets"
    environment:
      CUSTOM_VAR: "value"
      API_KEY: "your-api-key"
    working_dir: "/home/abc/${OC_PROJECT_NAME}/src"
```

#### Combining network and volume customizations

```yaml
services:
  opencode:
    networks:
      - kiwifs-net
    volumes:
      - "${HOME}/gtd-kiwi-fs:/home/abc/gtd-kiwi-fs"
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

| Path                       | Maps to in container | Purpose                                                                                                                                                                                                     |
| -------------------------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `dot-config/`              | `~/.config/`         | Everything OpenCode reads from its XDG default location — skills, agents, commands, themes, plugins (`~/.config/opencode/*`), plus the seeded `opencode.jsonc` and `cli.json` (see "Config seeding" below). |
| `dot-local/`               | `~/.local/`          | DB, auth, sessions, prompt history, model selection                                                                                                                                                         |
| `dot-cache/`               | `~/.cache/`          | Download/build cache, agent binaries                                                                                                                                                                        |
| `dot-npm/`                 | `~/.npm/`            | Plugin/skill dependency cache                                                                                                                                                                               |
| `dot-ssh/`                 | `~/.ssh/`            | SSH keys (generated on first run)                                                                                                                                                                           |
| `dot-gitconfig/.gitconfig` | `~/.gitconfig`       | Git identity (prompted on first run)                                                                                                                                                                        |

### Config seeding

Two source templates live in the cloned repo: `opencode.jsonc.cloud.template` (for third-party providers) and `opencode.jsonc.local.template` (for llama.cpp or Docker Model Runner). `opencode-init.sh` deploys the one you chose as `opencode.jsonc.template` at the script root, alongside `cli.json.template`.

On every launch, `opencode-run.sh` **moves** whichever of them exist into `${HOME}/OpenCode/dot-config/opencode/` — stripping the `.template` suffix so each becomes `opencode.jsonc` and `cli.json` — which is bind-mounted to `~/.config/opencode/` inside the container, the XDG default OpenCode reads from.

The script root is a **transient handoff slot**, not a permanent home for the config files:

- First launch after `opencode-init.sh`: the two template files exist at the script root → `opencode-run.sh` moves them into `dot-config/opencode/`. If the destination files already exist, they are first copied to a timestamped backup (e.g. `20260716-143022_opencode.jsonc.backup`) before being overwritten.
- Subsequent launches: the script root is empty → the move step is silently skipped, and OpenCode continues reading the previously-seeded files from `dot-config/opencode/`.
- If you never run `opencode-init.sh` (or you delete the source files), the move step is skipped on every launch and OpenCode falls back to whatever defaults it writes itself.

**To push updated config:** edit the canonical templates in your cloned repo, re-run `opencode-init.sh` (which re-copies them into the script root, prompting on overwrite), then launch with `opencode` — the move step picks them up. Any existing config at the destination is backed up automatically.

Edit config files on the host; changes take effect on the next container start. Auth, sessions, and DB persist across image rebuilds.

## Files

- `opencode-init.sh` — Host-side first-time-setup script. Copies the project tree to `${HOME}/OpenCode/` (excluding `README.md`, `AGENTS.md`, `LICENSE`, `.git*`, the `opencode.jsonc.*.template` files, and itself), prompts before overwriting existing files, prompts for cloud/local configuration mode (deploys the chosen template as `opencode.jsonc.template`), and installs the `opencode` alias in `~/.bashrc` if not already present. Remembers the cloud/local choice in `${HOME}/OpenCode/.config-mode` and the local backend in `${HOME}/OpenCode/.local-backend`; re-run to update files; delete either file to re-prompt. Idempotent; safe to re-run.
- `Dockerfile` — Ubuntu 26.04 base. Installs Node + uv + OpenCode toolchain; copies the OpenCode binary to `/usr/local/bin/` so it survives any bind mount under `/home/abc`. Hardening borrowed from linuxserver.io: `userdel ubuntu` removes the default UID-1000 user that ships with 26.04 (eliminates a PUID collision), `locales` is installed and `en_US.UTF-8` generated to prevent TUI/encoding glitches, and the `abc` user is created via `useradd -u 911 -U` (matching group auto-created; GID is remapped at runtime).
- `entrypoint.sh` — Remaps `abc` UID/GID to host `PUID`/`PGID`, starts a headless Xvfb display so clipboard copy works, then drops privileges via `gosu`.
- `opencode-run.sh` — Host-side launcher. Parses `--model`, reads the backend from `.local-backend`, validates overlays, bootstraps host directories and git/SSH identity, then invokes compose with the selected model overlay. llama.cpp: checks the GGUF, starts/reuses `llama-server`, and stops it on exit if no other session uses it. DMR: unloads conflicting models first. Detects and merges `extra-compose.yaml` from workspace directory for per-project OpenCode service customization (may modify existing services, not add new ones).
- `docker-compose.yaml` — Base service definition: volume mounts, environment, healthcheck, `opencode-net`, and `command: opencode --standalone` (see [Running several sessions at once](#running-several-sessions-at-once)). **No model backend** — see `docker-compose.llama-cpp.yaml` and `models/`.
- `docker-compose.llama-cpp.yaml` — The `llama-server` service (ROCm image, GPU devices, read-only models mount) plus `ACTIVE_MODEL_URL`/`ACTIVE_MODEL_NAME` for OpenCode. Merged only in local mode with the llama.cpp backend.
- `models/cpp/*.yaml` — llama.cpp overlays: GGUF path (`LLAMA_ARG_MODEL`), llama-server flags (`command:`), and `ACTIVE_MODEL_DISPLAY_NAME`.
- `models/dmr/*.yaml` — Docker Model Runner overlays: one `llm_active` binding plus `ACTIVE_MODEL_DISPLAY_NAME`.
- `opencode.jsonc.cloud.template` — Cloud configuration template. Uses the `opencode-go` provider with a third-party model.
- `opencode.jsonc.local.template` — Local configuration template. Defines an `active` provider that reads `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`, and `ACTIVE_MODEL_DISPLAY_NAME` from env vars set by the backend (`docker-compose.llama-cpp.yaml` or the DMR binding) and the model overlay.
- `cli.json.template` — CLI/TUI settings template.
- `opencode-init.sh` deploys one of the `opencode.jsonc.*.template` files as `opencode.jsonc.template` at the script root based on your cloud/local choice. `opencode-run.sh` then moves it (and `cli.json.template`) into `${HOME}/OpenCode/dot-config/opencode/` on every launch (`.template` suffix is stripped, producing `opencode.jsonc` and `cli.json`), which the container sees at `~/.config/opencode/` (the XDG default). Edit the source templates to change the config; delete them to fall back to OpenCode-generated defaults.

## Running several sessions at once

OpenCode runs with `--standalone` (see `command:` in `docker-compose.yaml`), so each container has its own private server. OpenCode V2's shared background service registers itself in `~/.local/state/opencode/service.json`. That file is shared across containers, but each container has its own `127.0.0.1`, so parallel sessions kept replacing each other's service. Each session now costs a little more memory (one server per container).

## Troubleshooting: "Background service failed to start"

**Symptom:** OpenCode exits right after starting. Before the switch to `--standalone`, the error was `Error: Background service failed to start`; either way the log shows `database migration failed`.

**Cause:** On startup, OpenCode 2.0.20 runs database migration `20260812213948_worktree`. It fails with `FOREIGN KEY constraint failed` because the persisted DB has orphaned `project_directory` rows, so the server exits on every launch. The log is `~/OpenCode/dot-local/share/opencode/log/opencode.log`.

**Fix:** `cd` into the data directory, back up the DB, delete the orphaned rows, then relaunch:

```bash
cd ~/OpenCode/dot-local/share/opencode/
cp opencode.db opencode.db.bak
sqlite3 opencode.db "DELETE FROM project_directory WHERE project_id NOT IN (SELECT id FROM project);"
```

If that doesn't work, move `opencode.db` aside so OpenCode creates a fresh one. You lose existing sessions.
