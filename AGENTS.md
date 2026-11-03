# AGENTS.md

This repo packages OpenCode in a Docker container for local development. It is
not an application — the "code" is shell scripts, a Dockerfile, compose files,
and per-model YAML overlays. There is no lint config, CI, or build step;
verification is launching the container with `./opencode-run.sh`, plus
`tests/init-instance.sh` for init's directory/alias rules.

## Architecture in one paragraph

`opencode-init.sh` runs once per instance on the host: it asks for an
instance directory (default `~/OpenCode/`), copies repo artifacts there, and
installs an alias named after the lowercased directory (`~/OpenCode-llama` →
`opencode-llama`). Below, `~/OpenCode/` means the instance directory. `opencode-run.sh` is the
per-launch entrypoint: parses `--model <shortname>`, reads the local backend
(`cpp` = llama.cpp, default; `dmr` = Docker Model Runner; `remote` = a
standalone llama-server) from `~/OpenCode/.local-backend`, runs that
backend's pre-flight, bootstraps host-side dirs, seeds config, starts/reuses
`llama-server` (cpp only), then `docker compose run`. `llama-cpp-run.sh`
runs llama-server on its own (background, published port) for `remote`
clients on this machine or the LAN.
`docker-compose.yaml` defines the base service with NO model backend; with
`--model`, one `models/<backend>/<shortname>.yaml` overlay is merged in, plus
`docker-compose.llama-cpp.yaml` (the llama-server service) for `cpp`.
`entrypoint.sh` remaps the in-container `abc` user's UID/GID to the host's
`PUID`/`PGID` at runtime (no rebuild needed for different host users). An
optional `extra-compose.yaml` in the workspace directory can customize the
OpenCode service (networks, volumes, environment) — it may modify existing
services but not add new ones.

## Commands

- `./opencode-init.sh` — one-time host setup; idempotent. Re-run after edits
  to repo-root templates to re-copy them to `~/OpenCode/`.
- `./opencode-run.sh --model <shortname> [/path/to/project]` — local model mode.
- `./opencode-run.sh [/path/to/project]` — cloud/third-party provider mode.
- `./opencode-run.sh --help` — lists available model overlays.
- `./llama-cpp-run.sh --model <shortname> | --stop | --logs` — standalone
  llama-server for the `remote` backend (`LLAMA_PORT`, `LLAMA_API_KEY`).
- `./tests/init-instance.sh` — runs init in a throwaway `HOME` and checks the
  instance-directory and alias rules. Run it after editing `opencode-init.sh`.
- `./tests/extra-compose.sh` — runs `opencode-run.sh` with a stub `docker` and
  checks the `extra-compose.yaml` approval and no-new-services rules, and that
  cloud mode rejects `--model`.
  Otherwise nothing to build or lint; edit scripts and re-launch to verify.
- If the workspace contains `extra-compose.yaml`, it is merged into the compose
  invocation for per-project customization. It may modify existing services but
  not add new ones.

## Git workflow

Commit directly to `main`. Remote is Codeberg over SSH
(`ssh://git@codeberg.org/aaronvonawesome/opencode-docker-compose.git`). No
branches, PRs, or tags in current history; no CI to satisfy.

## Gotchas an agent would otherwise miss

- **Config seeding is a move, not a copy.** `opencode.jsonc.template` and
  `cli.json.template` at the script root (`~/OpenCode/`) are _moved_ into
  `~/OpenCode/dot-config/opencode/` (suffix stripped) on each launch. After
  the first launch the slot is empty and the move is skipped silently. The
  deployed `opencode.jsonc.template` is produced by `opencode-init.sh`, which
  copies either `opencode.jsonc.cloud.template` or
  `opencode.jsonc.local.template` from the cloned repo based on the user's
  cloud/local choice. **To push an updated config: edit the chosen template
  in the cloned repo, re-run `opencode-init.sh`, then launch** — the move
  step picks it up. Existing destination files are backed up with a
  timestamp prefix before overwrite.
- **Cloud mode requires the cloud template.** `opencode-init.sh` deploys
  `opencode.jsonc.template` from either `opencode.jsonc.cloud.template` or
  `opencode.jsonc.local.template` based on your choice. If you initially
  chose local but want to switch to cloud (or vice versa), delete
  `~/OpenCode/.config-mode` and re-run `opencode-init.sh` — it will
  re-prompt and deploy the other template. The cloud template uses the
  `opencode-go` provider and has no local `active` provider block.
- **Local backend is chosen at init, not per launch.** In local mode,
  `opencode-init.sh` prompts `[c] llama.cpp` (default) / `[d] Docker Model
  Runner` / `[r] Remote llama.cpp server` and saves `cpp`/`dmr`/`remote` to
  `~/OpenCode/.local-backend`. Missing file → `cpp`. To switch: delete it and
  re-run init. `--help` lists only `models/<backend>/` overlays.
- **Remote backend** (`remote`, only honored when `.config-mode` is `local`):
  init saves the URL to `.remote-llama-url` (default
  `http://host.docker.internal:8080/v1`) and the optional key to
  `.remote-llama-key` (mode 600). `opencode-run.sh` rejects `--model`, curls
  `<url>/models` on the host (`host.docker.internal` → `localhost`) to get
  the model ID, then GETs `<url>/chat/completions` and aborts on 401 (`/models`
  is open even with a key, so it can't catch a bad key). The key is piped via
  `curl -H @-` so it stays out of `ps`. It then passes
  `ACTIVE_MODEL_URL/NAME/DISPLAY_NAME/API_KEY` via
  name-only `docker compose run -e`. It never starts or stops the server.
  The local template's `apiKey` reads `ACTIVE_MODEL_API_KEY` (empty → no
  header).
- **Standalone server** (`llama-cpp-run.sh`): compose project
  `llama-cpp-standalone`, container `llama-server-standalone`, files
  `docker-compose.llama-cpp.yaml` + `docker-compose.llama-cpp-standalone.yaml`
  + `models/cpp/<shortname>.yaml`. The standalone file adds `ports:`,
  `restart: unless-stopped`, a value-less `LLAMA_ARG_API_KEY` (exported only
  when `LLAMA_API_KEY` is non-empty, so an empty key never reaches llama.cpp),
  and the `opencode-net` network. Same config-hash rule as the per-session
  server: match → skip the wait and print URLs; otherwise prompt and
  `up -d --force-recreate`. The down paths (`--stop`, and the EXIT trap after
  a failed start or health wait) pass `-f docker-compose.llama-cpp.yaml -f
  docker-compose.llama-cpp-standalone.yaml` explicitly and run from the repo
  root, so compose never picks up a stray `docker-compose.yaml` from the
  caller's CWD; `--remove-orphans` is kept as belt-and-braces. The trap is
  armed before the start and removed on reuse (10) and on a declined restart
  prompt (11), so a healthy server the user chose to keep is never removed
  (otherwise `restart: unless-stopped` crash-loops the failed container); the
  trap is cleared once healthy.
  If the running container has `LLAMA_ARG_API_KEY` and `LLAMA_API_KEY` is
  empty, the restart prompt warns that the port would open — the key lives
  only in the starting shell's env.
- **Shared llama.cpp code lives in `llama-cpp-lib.sh`** (`llama_preflight`,
  `llama_start_or_reuse`, `llama_wait_healthy`), sourced by `opencode-run.sh`
  and `llama-cpp-run.sh`. Change start-up behavior there, not in either script.
  `llama_start_or_reuse` returns **10 on reuse** and exits **11 when the
  restart prompt is declined**; callers must handle both
  (`|| [[ $? -eq 10 ]]`). Being called after `||` disables `set -e` inside
  it, so any new failing step there needs an explicit `|| exit 1`.
- **cpp files must not define an `opencode` service.** The standalone
  project merges `docker-compose.llama-cpp.yaml` and `models/cpp/*.yaml`
  without `docker-compose.yaml`, so any `opencode:` block there becomes an
  image-less service and Compose fails. OpenCode's `ACTIVE_MODEL_*` values
  are passed by `opencode-run.sh` with `run -e` instead.
- **Adding a local model = one file in the backend's folder.**
  - `models/cpp/` (mirror `models/cpp/ornith15.yaml`):
    `services.llama-server.environment.LLAMA_ARG_MODEL: "/mnt/storage/llama-cpp/models/<file>.gguf"`,
    optional `services.llama-server.command:` flags, and the
    `services.llama-server.labels."opencode.display-name"` label. The
    launcher parses `LLAMA_ARG_MODEL` to check the file exists and the label
    for the picker name (falls back to the shortname).
  - `models/dmr/` (mirror `models/dmr/ornith15.yaml`): a
    `services.opencode.models.llm_active` block (`endpoint_var:
    ACTIVE_MODEL_URL`, `model_var: ACTIVE_MODEL_NAME`), the display-name env,
    and a top-level `models.llm_active.model:` DMR identifier (+ optional
    `runtime_flags`). `runtime_flags` apply only at first load: after editing
    them, `docker model unload` the model before relaunching, or the old
    flags keep serving.
  - Do not edit `docker-compose.yaml` or `opencode-run.sh`.
- **Current overlays.** `cpp`: `ornith15`, `qwen3827b`, `glm47flash`. `dmr`:
  `ornith15`.
- **GGUFs are never downloaded (cpp).** They live in `OPENCODE_GGUF_DIR`
  (default `/mnt/storage/llama-cpp/models`), always mounted read-only at that
  same path in the container; `models/cpp/` overlays hardcode it.
- **DMR pre-flight** (dmr only): `docker model ps` is parsed; any other loaded
  model triggers a prompt, then `docker model unload` (case-preserved name
  from `docker model list`). The `docker-model-runner` container shows
  `(unhealthy)` for ~2 min during large loads — cosmetic; the DMR plugin
  reasserts its healthcheck, so `docker update --health-*` doesn't stick.
- **One shared `llama-server` container** (cpp only; fixed `container_name`,
  label `opencode.model=<shortname>`). Same Compose config hash → reused;
  different model or edited overlay → prompt, then `up -d --force-recreate`.
  cpp sessions are labeled `opencode.uses-llama=true`; an EXIT trap stops and
  removes llama-server when none remain. Cloud, DMR, and remote sessions never
  touch it.
- **ROCm only (cpp).** The image is `server-rocm`; video/render GIDs come from
  `getent` on the host (fallback 44/992).
- **OpenCode runs `--standalone`** (`command:` in `docker-compose.yaml`).
  Without it, every container registers its background service in the shared
  `~/.local/state/opencode/service.json`. Each container's `127.0.0.1` is its
  own, so a second container can't reach the first's service: it starts its
  own, overwrites the file, and the first shuts down ("managed service
  registration replaced"), in a loop.
- **Multiple instances.** Each instance directory holds its own `dot-*`,
  `container-tmp`, `development`, `.config-mode`, `.local-backend` and remote
  files. `opencode-run.sh` uses `SCRIPT_DIR` for all of them, and
  `docker-compose.yaml` mounts them as `./dot-*` (relative to the instance
  dir); never hardcode `${HOME}/OpenCode`. Only one instance should use the `cpp` backend
  (the `llama-server` container is shared).
- **Image tag is namespaced by `sha512(hostname)[:12]`** as
  `local/<id>/opencode:latest-stable`, so all instances on a host share one
  image.
- **OpenCode binary lives at `/usr/local/bin/opencode`**, deliberately outside
  `/home/abc` so bind mounts can't mask it. Runtime state goes to XDG paths
  (`~/.config/opencode`, `~/.local/...`, `~/.cache/...`), all bind-mounted
  from `~/OpenCode/dot-*` on the host.
- **Dockerfile pre-deletes the default `ubuntu` user (UID 1000)** to avoid a
  PUID collision with the most common host UID. The `abc` user is created at
  UID 911 and remapped at runtime via `entrypoint.sh` + `gosu`.
- **Healthcheck in `docker-compose.yaml`** is `pgrep -x opencode` with a 60s
  `start_period` to cover first-run DB migration. For cpp, the launcher waits
  on llama-server's `/health` via `docker exec … curl` (5 min cap) before
  starting OpenCode. No host port is published; llama-server is
  `opencode-net` only.
- **Experimental env vars removed for V2.** `OPENCODE_EXPERIMENTAL_LSP_TOOL`
  was inert in V2 (no LSP runtime yet) and
  `OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT` is superseded by
  `terminal.copy: "manual"` in `cli.json`. Both were removed from
  `docker-compose.yaml`.
- **`extra-compose.yaml` validation.** If a workspace directory contains an
  `extra-compose.yaml` file, it is merged into the compose invocation for
  per-project customization. The agent can write the workspace, so new or
  changed content needs a y/N: the launcher copies it to
  `~/OpenCode/.approved-extra-compose/<sha256>.yaml` and merges that copy
  (approved once per content; no TOCTOU). The copy is
  `docker compose config --no-interpolate --no-normalize --no-consistency`
  output (minus `name:`, which would override `opencode-va`), so
  `extends:`/`include:` targets are inlined at approval. It then compares
  `docker compose config --services` with and without it and rejects any new service (e.g. `kiwifs`).
  Modifying existing services (`opencode`, and `llama-server` on cpp) is
  allowed. Relative paths in it resolve against `~/OpenCode/` (first `-f`
  file), not the workspace; the workspace is mounted at
  `/home/abc/${OC_PROJECT_NAME}`.

## Repo layout

```
opencode-init.sh        # one-time host setup (copies to ~/OpenCode/, installs alias)
opencode-run.sh         # per-launch host-side entrypoint
docker-compose.yaml     # base OpenCode service (runs --standalone), NO model backend
Dockerfile              # ubuntu:26.04 + node + uv + opencode binary at /usr/local/bin
entrypoint.sh           # in-container UID/GID remap + Xvfb (clipboard) + gosu drop-privileges
docker-compose.llama-cpp.yaml # llama-server service; merged only with --model on the cpp backend
docker-compose.llama-cpp-standalone.yaml # overrides for llama-cpp-run.sh (port, restart, API key)
llama-cpp-run.sh        # standalone llama-server for the remote backend
llama-cpp-lib.sh        # shared llama.cpp steps (GGUF check, start-or-reuse, health wait), sourced by both
models/cpp/<shortname>.yaml   # llama.cpp overlay (GGUF + flags)
models/dmr/<shortname>.yaml   # Docker Model Runner overlay (llm_active binding)
opencode.jsonc.cloud.template # cloud config (third-party provider); deployed as opencode.jsonc.template by init
opencode.jsonc.local.template # local config (llama.cpp or DMR); deployed as opencode.jsonc.template by init
cli.json.template      # CLI/TUI settings (theme, mouse, attention, terminal, etc.); same move semantics
```

Host-side persistent layout (created by `opencode-run.sh`) lives at
`~/OpenCode/{dot-config,dot-local,dot-cache,dot-npm,dot-ssh,dot-gitconfig}` —
not in this repo.
