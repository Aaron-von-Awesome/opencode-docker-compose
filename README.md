# OpenCode + Docker Compose + Docker Model Runner

A local development environment for OpenCode, fully contained in a Docker container. Provides a linuxserver.io-style `abc` user with runtime UID/GID remapping, host-side persistent config and state, and a single-command launch.

## Prerequisites

- Docker with the Compose plugin (`docker compose ...`)

## Quick start

```bash
./opencode-run.sh [/path/to/your/project]
```

If no path is given, the current directory is used. The script:

1. Computes a `DIRECTORY_ID` to namespace the local image tag (`local/${DIRECTORY_ID}/opencode:latest-stable`).
2. Bootstraps host-side directories under `${HOME}/OpenCode/...` (see below).
3. On first run, prompts for git identity and generates an SSH key (`id_opencode`).
4. Builds the image if needed, then `docker compose run --rm opencode`.

## Host-side layout (`${HOME}/OpenCode/...`)

| Path                               | Maps to in container  | Purpose                                             |
| ---------------------------------- | --------------------- | --------------------------------------------------- |
| `dot-opencode/`                    | `OPENCODE_CONFIG_DIR` | Skills, agents, commands, themes, plugins           |
| `dot-opencode-json/opencode.jsonc` | `OPENCODE_CONFIG`     | Global OpenCode config                              |
| `dot-opencode-json/tui.jsonc`      | `OPENCODE_TUI_CONFIG` | TUI config                                          |
| `dot-local/`                       | `~/.local/`           | DB, auth, sessions, prompt history, model selection |
| `dot-cache/`                       | `~/.cache/`           | Download/build cache, agent binaries                |
| `dot-npm/`                         | `~/.npm/`             | Plugin/skill dependency cache                       |
| `dot-ssh/`                         | `~/.ssh/`             | SSH keys (generated on first run)                   |
| `dot-gitconfig/.gitconfig`         | `~/.gitconfig`        | Git identity (prompted on first run)                |

Edit config files on the host; changes take effect on the next container start. Auth, sessions, and DB persist across image rebuilds.

## Files

- `Dockerfile` — Ubuntu 24.04 base; installs OpenCode via the official installer, then copies the binary to `/usr/local/bin/` so it survives bind mounts.
- `entrypoint.sh` — Remaps `abc` UID/GID to host `PUID`/`PGID`, then drops privileges via `gosu`.
- `opencode-run.sh` — Host-side launcher (UID/GID export, host-dir bootstrap, git/SSH bootstrap, compose invocation).
- `docker-compose.yaml` — Service definition, volume mounts, env-var-driven config paths.
