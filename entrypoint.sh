#!/usr/bin/env bash
set -e

PUID=${PUID:-1000}
PGID=${PGID:-1000}

# Adjust the abc group/user to match requested PUID/PGID
groupmod -o -g "${PGID}" abc
usermod -o -u "${PUID}" abc

# Re-apply ownership of the home dir to the (newly remapped) abc user.
# usermod without -m leaves home-dir ownership at the original UID, so
# without this, abc can't write dotfiles into its own home.
chown abc:abc /home/abc

echo "───────────────────────────────────────"
echo " OpenCode Container"
echo "───────────────────────────────────────"
echo " User UID:    $(id -u abc)"
echo " User GID:    $(id -g abc)"
echo "───────────────────────────────────────"

# Start a headless X display so OpenCode's clipboard works (xclip/xsel
# need a DISPLAY). Xvfb binds per-container, so :99 is always free here.
if [ -z "${DISPLAY}" ]; then
  Xvfb :99 -screen 0 1280x1024x24 >/dev/null 2>&1 &
  export DISPLAY=:99
  for i in $(seq 1 20); do
    xdpyinfo -display :99 >/dev/null 2>&1 && break
    sleep 0.1
  done
fi

# Drop privileges and exec the CMD as the abc user
exec gosu abc "$@"
