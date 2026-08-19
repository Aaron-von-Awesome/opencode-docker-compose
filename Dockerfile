FROM ubuntu:26.04

ARG NODE_MAJOR_VERSION=26
ARG UV_VERSION=0.12.5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Locale defaults. Generated in the apt RUN below.
ENV LANG=en_US.UTF-8 \
  LANGUAGE=en_US.UTF-8 \
  LC_ALL=en_US.UTF-8

# Install Node.js and development tools
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  locales && \
  locale-gen en_US.UTF-8 && \
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR_VERSION}.x | bash - && \
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
  python-is-python3 && \
  ripgrep \
  sqlite3 \
  sudo \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Install uv package manager (version 0.11.6)
RUN curl -L https://releases.astral.sh/github/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz -o uv.tar.gz \
  && tar -xzf uv.tar.gz -C /usr/local/bin --strip-components=1 uv-x86_64-unknown-linux-gnu/ \
  && chmod +x /usr/local/bin/uv \
  && chmod +x /usr/local/bin/uvx \
  && rm uv.tar.gz

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
#
# Note: the bind-mount target for $OPENCODE_CONFIG_DIR
# (/home/abc/OpenCode/dot-opencode) is intentionally NOT pre-created here.
# Docker auto-creates the path (root-owned, mode 755) at mount time, which
# `abc` can traverse, and entrypoint.sh chowns the mount contents at
# runtime once PUID/PGID are remapped.
RUN curl -fsSL https://opencode.ai/install | bash && \
  install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode && \
  rm -rf /root/.opencode

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["opencode"]
