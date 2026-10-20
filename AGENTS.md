# AGENTS.md

This repo packages OpenCode in a Docker container for local development. It is
not an application — the "code" is shell scripts, a Dockerfile, compose files,
and per-model YAML overlays. There is no test suite, lint config, CI, or
build step; verification is launching the container with `./opencode-run.sh`.

## Architecture in one paragraph

`opencode-init.sh` runs once on the host: it copies repo artifacts to
`~/OpenCode/` and installs the `opencode` shell alias. `opencode-run.sh` is the
per-launch entrypoint: parses `--model <shortname>`, runs a Model Runner
pre-flight, bootstraps host-side dirs, seeds config, then `docker compose run`.
`docker-compose.yaml` defines the base service with NO model bindings; each
`models/<shortname>.yaml` overlay merges in exactly one `llm_active` binding.
`entrypoint.sh` remaps the in-container `abc` user's UID/GID to the host's
`PUID`/`PGID` at runtime (no rebuild needed for different host users). An
optional `extra-compose.yaml` in the workspace directory can customize the
OpenCode service (networks, volumes, environment) — validated to allow only
`opencode` service modifications.

## Commands

- `./opencode-init.sh` — one-time host setup; idempotent. Re-run after edits
  to repo-root templates to re-copy them to `~/OpenCode/`.
- `./opencode-run.sh --model <shortname> [/path/to/project]` — local model mode.
- `./opencode-run.sh [/path/to/project]` — cloud/third-party provider mode.
- `./opencode-run.sh --help` — lists available model overlays.
- Inside the repo there is nothing to build, test, or lint. Edit scripts and
  re-launch to verify.
- If the workspace contains `extra-compose.yaml`, it is merged into the compose
  invocation for per-project OpenCode service customization. Validated to ensure
  only the `opencode` service is modified (no additional services).

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
- **Adding a local model = one file.** Mirror `models/ornith15.yaml`: a
  `services.opencode.models.llm_active` block referencing `ACTIVE_MODEL_URL` /
  `ACTIVE_MODEL_NAME` env vars, plus an `environment:` block setting
  `ACTIVE_MODEL_DISPLAY_NAME`, and a top-level `models.llm_active.model:`
  Docker Model Runner identifier. Do not edit `docker-compose.yaml` or
  `opencode-run.sh`.
- **Exactly one model is bound per launch** — Docker Model Runner has no
  documented concurrency cap, so the launcher will prompt to unload any other
  currently-loaded model before starting. `--model` is required to trigger the
  pre-flight; omitting it skips Model Runner entirely.
- **`docker-model-runner` shows `(unhealthy)` for ~2 min** during large model
  loads. This is cosmetic — inference works regardless. The DMR plugin
  reasserts the image's healthcheck each binding cycle, so `docker update
--health-*` workarounds do not stick. Ignore the annotation.
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
  `start_period` to cover first-run DB migration. It is independent of the
  DMR backend container's own healthcheck (which we cannot configure).
- **Experimental env vars removed for V2.** `OPENCODE_EXPERIMENTAL_LSP_TOOL`
  was inert in V2 (no LSP runtime yet) and
  `OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT` is superseded by
  `terminal.copy: "manual"` in `cli.json`. Both were removed from
  `docker-compose.yaml`.
- **`extra-compose.yaml` validation.** If a workspace directory contains an
  `extra-compose.yaml` file, it is merged into the compose invocation for
  per-project customization. The file is validated to ensure it only modifies
  the `opencode` service — defining additional services (e.g., `kiwifs`,
  `database`) is rejected with an error. This prevents accidentally adding
  new services to the compose project while allowing network, volume, and
  environment customizations.

## Repo layout

```
opencode-init.sh        # one-time host setup (copies to ~/OpenCode/, installs alias)
opencode-run.sh         # per-launch host-side entrypoint
docker-compose.yaml     # base service, NO model bindings
Dockerfile              # ubuntu:26.04 + node + uv + opencode binary at /usr/local/bin
entrypoint.sh           # in-container UID/GID remap + gosu drop-privileges
models/<shortname>.yaml # one overlay per local model; merge via --model <shortname>
opencode.jsonc.cloud.template # cloud config (third-party provider); deployed as opencode.jsonc.template by init
opencode.jsonc.local.template # local config (Docker Model Runner); deployed as opencode.jsonc.template by init
cli.json.template      # CLI/TUI settings (theme, mouse, attention, terminal, etc.); same move semantics
```

Host-side persistent layout (created by `opencode-run.sh`) lives at
`~/OpenCode/{dot-config,dot-local,dot-cache,dot-npm,dot-ssh,dot-gitconfig}` —
not in this repo.
