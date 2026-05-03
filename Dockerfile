FROM ubuntu:24.04

ARG NODE_MAJOR_VERSION=24
ARG UV_VERSION=0.11.8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install Node.js and development tools
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg && \
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR_VERSION}.x | bash - && \
  apt-get install -y --no-install-recommends \
  nodejs \
  openssh-client \
  git \
  procps \
  sudo \
  jq \
  fzf \
  ripgrep \
  gosu \
  python3 \
  python-is-python3 && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Install uv package manager (version 0.11.6)
RUN curl -L https://releases.astral.sh/github/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz -o uv.tar.gz \
  && tar -xzf uv.tar.gz -C /usr/local/bin --strip-components=1 uv-x86_64-unknown-linux-gnu/ \
  && chmod +x /usr/local/bin/uv \
  && chmod +x /usr/local/bin/uvx \
  && rm uv.tar.gz

# Create default user "abc" (linuxserver convention) with placeholder UID/GID
RUN groupadd -g 911 abc && \
  useradd -u 911 -g 911 -m -d /home/abc -s /bin/bash abc

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
