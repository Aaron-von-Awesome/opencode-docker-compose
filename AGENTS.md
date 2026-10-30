# AGENTS.md

This repo packages OpenCode in a Docker container for local development. It is
not an application — the "code" is shell scripts, a Dockerfile, compose files,
and per-model YAML overlays. There is no test suite, lint config, CI, or
build step; verification is launching the container with `./opencode-run.sh`.

## Architecture in one paragraph

`opencode-init.sh` runs once on the host: it copies repo artifacts to
`~/OpenCode/` and installs the `opencode` shell alias. `opencode-run.sh` is the
per-launch entrypoint: parses `--model <shortname>`, reads the local backend
(`cpp` = llama.cpp, default; `dmr` = Docker Model Runner) from
`~/OpenCode/.local-backend`, runs that backend's pre-flight, bootstraps
host-side dirs, seeds config, starts/reuses `llama-server` (cpp only), then
`docker compose run`.
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
- Inside the repo there is nothing to build, test, or lint. Edit scripts and
  re-launch to verify.
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
  Runner` and saves `cpp`/`dmr` to `~/OpenCode/.local-backend`. Missing file
  → `cpp`. To switch: delete it and re-run init. `--help` lists only
  `models/<backend>/` overlays.
- **Adding a local model = one file in the backend's folder.**
  - `models/cpp/` (mirror `models/cpp/ornith15.yaml`):
    `services.llama-server.environment.LLAMA_ARG_MODEL: "/mnt/storage/llama-cpp/models/<file>.gguf"`,
    optional `services.llama-server.command:` flags, and
    `services.opencode.environment.ACTIVE_MODEL_DISPLAY_NAME`. The launcher
    parses `LLAMA_ARG_MODEL` to check the file exists.
  - `models/dmr/` (mirror `models/dmr/ornith15.yaml`): a
    `services.opencode.models.llm_active` block (`endpoint_var:
    ACTIVE_MODEL_URL`, `model_var: ACTIVE_MODEL_NAME`), the display-name env,
    and a top-level `models.llm_active.model:` DMR identifier (+ optional
    `runtime_flags`).
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
  removes llama-server when none remain. Cloud and DMR sessions never touch it.
- **ROCm only (cpp).** The image is `server-rocm`; video/render GIDs come from
  `getent` on the host (fallback 44/992).
- **OpenCode runs `--standalone`** (`command:` in `docker-compose.yaml`).
  Without it, every container registers its background service in the shared
  `~/.local/state/opencode/service.json`. Each container's `127.0.0.1` is its
  own, so a second container can't reach the first's service: it starts its
  own, overwrites the file, and the first shuts down ("managed service
  registration replaced"), in a loop.
- **Image tag is namespaced by `sha512(script_dir + hostname)[:12]`** as
  `local/<id>/opencode:latest-stable`. Building/launching from a different
  directory or host produces a different image and a fresh build.
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
  per-project customization. The launcher compares `docker compose config
  --services` with and without it and rejects any new service (e.g. `kiwifs`).
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
models/cpp/<shortname>.yaml   # llama.cpp overlay (GGUF + flags)
models/dmr/<shortname>.yaml   # Docker Model Runner overlay (llm_active binding)
opencode.jsonc.cloud.template # cloud config (third-party provider); deployed as opencode.jsonc.template by init
opencode.jsonc.local.template # local config (llama.cpp or DMR); deployed as opencode.jsonc.template by init
cli.json.template      # CLI/TUI settings (theme, mouse, attention, terminal, etc.); same move semantics
```

Host-side persistent layout (created by `opencode-run.sh`) lives at
`~/OpenCode/{dot-config,dot-local,dot-cache,dot-npm,dot-ssh,dot-gitconfig}` —
not in this repo.
