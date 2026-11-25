# OpenCode V2 + Docker Compose + llama.cpp / Docker Model Runner

OpenCode V2 in a Docker container, with optional local models from llama.cpp (default) or Docker Model Runner (DMR). The in-container `abc` user is remapped to your UID/GID at runtime, and config and state persist on the host.

## Prerequisites

- Docker with the Compose plugin.
- llama.cpp: an AMD GPU with ROCm (`/dev/kfd`, `/dev/dri`) or any Vulkan GPU (`/dev/dri`, chosen at init; Compose ≥ 2.24), and GGUF files in `/mnt/storage/llama-cpp/models` (override with `OPENCODE_GGUF_DIR`).
- DMR: Docker Model Runner enabled.
- Remote llama.cpp: `curl` on the host.

## Setup

```bash
./opencode-init.sh
source ~/.bashrc
```

Init is safe to re-run. It:

1. Asks for an instance directory (default `~/OpenCode/`) and copies the repo there (asks before overwriting).
2. Asks **cloud** or **local** and deploys the matching `opencode.jsonc` template. Saved to `~/OpenCode/.config-mode`.
3. Local only: asks for a backend — `[c]` llama.cpp (default), `[d]` DMR, or `[r]` remote llama.cpp server. Saved to `~/OpenCode/.local-backend`. Remote also asks for the server URL and API key.
4. Adds an alias named after the lowercased directory to `~/.bashrc` (`~/OpenCode` → `opencode`, `~/OpenCode-llama` → `opencode-llama`).

Run init again with another directory to add an instance (e.g. one cloud, one llama.cpp). Each has its own config, state, SSH key and git identity, and they can run at the same time; they share the Docker image and GGUF dir. Only one instance should use the llama.cpp backend. Below, `~/OpenCode/` means the instance directory.

To change a saved choice, delete its file and re-run init.

### Init errors

Init checks the directory and its alias before copying anything. When a check fails, it stops and nothing changes, so fix the cause and re-run init.

- **Directory inside the repo:** pick a directory outside the clone.
- **Name can't be an alias:** the directory name may only use letters, digits, `.`, `_` and `-`, so no spaces.
- **Alias already exists for a different instance:** two directories with the same lowercased name (e.g. `~/OpenCode` and `~/work/opencode`) would need the same alias. The error shows the `~/.bashrc` line number. Pick a different directory name, or delete that line.
- **Alias would hide a command:** e.g. `~/Docker` would create an alias that hides the `docker` command. Pick a different directory name; there is no override.
- **Commented-out alias:** a `# alias <name>=...` line still counts, so `~/.bashrc` never gets a second one. If it belongs to a different instance, you get the same error as above and must delete that line or rename the directory. If it belongs to this instance, init finishes but adds no alias; uncomment the line to use it.

## Usage

```bash
opencode --model ornith15 [path]   # local model (cpp or dmr backend)
opencode [path]                    # cloud, or remote llama.cpp backend
opencode --help                    # usage + overlays for your backend
```

Path defaults to the current directory.

## Local backends

Overlays live in `models/<backend>/`; `--model <shortname>` picks one.

### llama.cpp (default)

| Shortname    | Display name       | GGUF                          |
| ------------ | ------------------ | ----------------------------- |
| `ornith15`   | Ornith 1.5 A3B 35B | `Ornith-1.5-35B-Q4_K_M.gguf`  |
| `qwen3827b`  | Qwen3.8 27B        | `Qwen3.8-27B-UD-Q4_K_XL.gguf` |
| `glm47flash` | GLM 4.7 Flash      | `GLM-4.7-Flash-Q4_K_M.gguf`   |

- One shared `llama-server` container (`ghcr.io/ggml-org/llama.cpp:server-rocm`, or `server-vulkan`) serves one model. GGUFs are never downloaded; a missing file aborts the launch.
- **Same model and config running:** reused. **Different model or edited overlay:** you're asked before it restarts (default: no).
- The launcher waits up to 5 min for `/health`. When the last llama.cpp session exits, the server is stopped and removed.
- Docker-network only (`http://llama-server:8080`). To reach it from the host, add `ports:` under `llama-server` in `~/OpenCode/docker-compose.llama-cpp.yaml` or a project's `extra-compose.yaml`.
- Logs: `docker logs -f llama-server`.

### Docker Model Runner

| Shortname  | DMR model                      |
| ---------- | ------------------------------ |
| `ornith15` | `ai/ornith-1.5:35b-a3b-q4_K_M` |

If other DMR models are loaded, you're asked before they're unloaded. The `docker-model-runner` container shows `(unhealthy)` for ~2 min during large loads — cosmetic, ignore it. `runtime_flags` apply only when the model is first loaded — after editing them, run `docker model unload <model>` before relaunching, or the old flags keep serving.

### Remote llama.cpp server

One standalone llama-server, on this machine or a LAN box, shared by any number of OpenCode instances. llama.cpp only.

**Server:** run `llama-cpp-run.sh` on the machine with the GPU and GGUFs. The script is in this repo and in every instance directory, since `opencode-init.sh` copies it there. Both copies work, and you can run it from any directory:

```bash
cd ~/OpenCode            # or your clone of this repo
LLAMA_API_KEY=change-me ./llama-cpp-run.sh --model ornith15   # start in background (add --gpu vulkan for Vulkan)
./llama-cpp-run.sh --logs                                     # follow logs
./llama-cpp-run.sh --stop                                     # stop and remove
```

- Publishes `${LLAMA_BIND:-0.0.0.0}:${LLAMA_PORT:-8080}` with `restart: unless-stopped`. Set `LLAMA_BIND` to one interface's IP (e.g. a Tailscale IP) to limit exposure. `127.0.0.1` also blocks same-machine OpenCode containers, since `host.docker.internal` is the Docker bridge IP, not loopback.
- **Without `LLAMA_API_KEY`, anyone who can reach the port can use it.** Generate one with `openssl rand -hex 32` and give clients the same value. It isn't saved on the server, so pass it again on every restart. If the running server has a key and your shell doesn't, the restart prompt warns you.
- The built-in Llama Chat UI is off by default. Start the server with `LLAMA_UI=1` to serve it from the same port. (served without the key — the key still gates API calls only)
- Same model and config running → just prints the URLs. Otherwise you're asked before a restart. A server that never gets healthy is removed, so it can't crash-loop.

**Clients:** run init, pick local → `[r]`, and enter the URL (`http://host.docker.internal:8080/v1` for the same machine, `http://<server-ip>:8080/v1` for LAN) and key. They're saved to `~/OpenCode/.remote-llama-url` and `~/OpenCode/.remote-llama-key` (mode 600); delete the URL file and re-run init to change both. Then launch with no `--model`. The launcher checks the server is up, the key is accepted, and which model is loaded, then connects. It never starts or stops the server.

## Adding a model

llama.cpp — `models/cpp/<shortname>.yaml` (don't add an `opencode:` service here):

```yaml
services:
  llama-server:
    labels:
      opencode.display-name: "My New Model"
    environment:
      LLAMA_ARG_MODEL: "/mnt/storage/llama-cpp/models/My-New-Model-Q4_K_M.gguf"
    command: ["--ctx-size", "65536"]   # optional per-model flags
```

Shared flags (`-ngl 999`, `--flash-attn on`, port, alias) live in `docker-compose.llama-cpp.yaml`.

DMR — `models/dmr/<shortname>.yaml`:

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
    model: <dmr-identifier>
```

The local `opencode.jsonc` defines one `active` provider fed by `ACTIVE_MODEL_URL`, `ACTIVE_MODEL_NAME`, `ACTIVE_MODEL_DISPLAY_NAME` (and `ACTIVE_MODEL_API_KEY` for remote), so the picker only ever shows the model you launched.

## Cloud mode

Omit `--model`. OpenCode uses the provider in `opencode.jsonc` (cloud template: `opencode-go`). If you chose local at init, delete `~/OpenCode/.config-mode` and re-run init.

## Per-project `extra-compose.yaml`

A workspace `extra-compose.yaml` is merged into the launch. It may change existing services (`opencode`, and `llama-server` on cpp) but not add new ones.

- New or changed content asks for a y/N first, since the agent can write your project. Approved copies live in `~/OpenCode/.approved-extra-compose/`.
- You approve the file as `docker compose config` resolves it, so `extends:`/`include:` targets are copied in and later edits to them have no effect.
- Relative paths resolve against `~/OpenCode/`, not your project. Use absolute paths, `${HOME}`, or `${WORKSPACE_DIR}`.
- Your project is mounted at `/home/abc/${OC_PROJECT_NAME}`.

```yaml
services:
  opencode:
    networks: [kiwifs-net]
    volumes:
      - "${HOME}/datasets:/home/abc/datasets"
    environment:
      KIWIFS_URL: "http://kiwifs:3333"

networks:
  kiwifs-net:
    external: true
```

## Host layout and config

| `~/OpenCode/...`           | Container      | Holds                                   |
| -------------------------- | -------------- | --------------------------------------- |
| `dot-config/`              | `~/.config/`   | `opencode.jsonc`, `cli.json`, skills, plugins |
| `dot-local/`               | `~/.local/`    | DB, auth, sessions                      |
| `dot-cache/`               | `~/.cache/`    | caches                                  |
| `dot-npm/`                 | `~/.npm/`      | plugin dependencies                     |
| `dot-ssh/`                 | `~/.ssh/`      | SSH key (generated on first run)        |
| `dot-gitconfig/.gitconfig` | `~/.gitconfig` | git identity (asked on first run)       |

Init leaves `opencode.jsonc.template` and `cli.json.template` in `~/OpenCode/`; the next launch **moves** them into `dot-config/opencode/`, backing up existing files. To push a config change: edit the template in the repo, re-run init, launch.

## Files

| File | Purpose |
| ---- | ------- |
| `opencode-init.sh` | One-time setup: copy, mode/backend prompts, alias |
| `opencode-run.sh` | Launcher |
| `llama-cpp-run.sh` | Standalone llama-server for the remote backend |
| `llama-cpp-lib.sh` | Shared llama.cpp steps (GGUF check, start-or-reuse, health wait) |
| `docker-compose.yaml` | Base OpenCode service (`--standalone`), no model backend |
| `docker-compose.llama-cpp.yaml` | `llama-server` service (cpp) |
| `docker-compose.llama-cpp-standalone.yaml` | Standalone overrides: port, restart, API key |
| `models/cpp/`, `models/dmr/` | One overlay per model |
| `opencode.jsonc.{cloud,local}.template` | Config templates (local disables request timeouts for slow prefills) |
| `cli.json.template` | TUI settings |
| `Dockerfile`, `entrypoint.sh` | Image; UID/GID remap, Xvfb for clipboard, `gosu` |
| `tests/init-instance.sh` | Checks init's directory and alias rules (not copied to instances) |
| `tests/extra-compose.sh` | Checks the `extra-compose.yaml` approval flow with a stub `docker` (not copied to instances) |
| `tests/llama-cpp-run.sh` | Checks the standalone launcher's `--gpu` flag, the API-key wiring and the UI default with a stub `docker` (not copied to instances) |
| `tests/overlays.sh` | Checks the overlay parsers (not copied to instances) |

## Tests

```bash
./tests/init-instance.sh
./tests/extra-compose.sh
./tests/llama-cpp-run.sh
./tests/overlays.sh
```

`init-instance.sh` runs `opencode-init.sh` in a throwaway `HOME` and checks the directory and alias rules above. `overlays.sh` checks the overlay parsers (`read_overlay_gguf`, `read_overlay_model_id`) against the real overlays, with no Docker needed. `extra-compose.sh` stubs `docker` to check the per-project file approval, the no-new-services rule, and cloud-mode/local-backend handling. `llama-cpp-run.sh` stubs `docker` to check the standalone server's `--gpu` flag, plus the reuse and declined-restart paths of the shared start-up logic. All four print `ok`/`FAIL` per case and exit non-zero on any failure; they don't touch your real `~/.bashrc` or instance directories.

## Troubleshooting

**Several sessions at once:** OpenCode runs `--standalone`, so each container has its own server. Without it, containers fight over the shared `service.json` and kill each other's sessions.

**"Background service failed to start" / `database migration failed`:** orphaned rows break migration `20260812213948_worktree`.

```bash
cd ~/OpenCode/dot-local/share/opencode/
cp opencode.db opencode.db.bak
sqlite3 opencode.db "DELETE FROM project_directory WHERE project_id NOT IN (SELECT id FROM project);"
```

If that fails, move `opencode.db` aside (you lose existing sessions).
