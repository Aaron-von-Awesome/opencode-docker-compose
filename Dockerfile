FROM ubuntu:26.04

ARG NODE_MAJOR_VERSION=26

# Locale defaults & UV Settings
ENV LANG=en_US.UTF-8 \
  LANGUAGE=en_US.UTF-8 \
  LC_ALL=en_US.UTF-8 \
  UV_TOOL_DIR=/opt/uv-tools \
  UV_TOOL_BIN_DIR=/usr/local/bin \
  UV_PYTHON_DOWNLOADS=never \
  UV_LINK_MODE=copy

# Install uv package manager (version 0.13.5)
COPY --from=ghcr.io/astral-sh/uv:0.13.5 /uv /uvx /usr/local/bin/

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install Node.js and development tools
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  locales && \
  locale-gen en_US.UTF-8 && \
  curl -fsSL --retry 5 --retry-all-errors https://deb.nodesource.com/setup_${NODE_MAJOR_VERSION}.x | bash - && \
  apt-get install -y --no-install-recommends \
  nodejs \
  direnv \
  fzf \
  git \
  git-lfs \
  gosu \
  iputils-ping \
  jq \
  openssh-client \
  procps \
  python3 \
  python-is-python3 \
  ripgrep \
  sqlite3 \
  x11-utils \
  xclip \
  xsel \
  xvfb && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Create default user "abc" (linuxserver convention) at placeholder UID 911.
# `-U` creates a same-named group automatically (GID auto-assigned; both
# UID and GID are remapped to PUID/PGID by entrypoint.sh at runtime, so
# the initial GID value is irrelevant).
#
# Also remove the default `ubuntu` user that ships with the base image — we
# never use it, and its UID 1000 collides with the most common host PUID,
# which would otherwise force the `usermod -o` remap into duplicate-UID
# territory. Removing it tightens containment.
RUN userdel -r ubuntu 2>/dev/null || true && \
  useradd -u 911 -U -m -d /home/abc -s /bin/bash abc

# Install OpenCode. The installer is hardcoded to write the binary to
# $HOME/.opencode/bin/opencode and offers no prefix override. We install
# as root, then copy the binary to /usr/local/bin so it (a) is on PATH for
# every user and (b) lives outside any path that could be masked by a
# bind mount under /home/abc. OpenCode's actual runtime state goes to
# XDG paths (~/.config/opencode, ~/.local/share/opencode, ~/.cache/opencode)
# which it creates on demand as user `abc` at first run.
RUN curl -fsSL --retry 5 --retry-all-errors https://opencode.ai/v2/install | bash && \
  install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode && \
  rm -rf /root/.opencode

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["opencode"]
