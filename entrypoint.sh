#!/usr/bin/env bash
set -e

PUID=${PUID:-1000}
PGID=${PGID:-1000}

# Adjust the abc group/user to match requested PUID/PGID
groupmod -o -g "${PGID}" abc
# -m moves home-dir ownership along with the new UID; without it, the image's
# build-time files (/home/abc/.profile etc.) would stay owned by UID 911.
usermod -m -o -u "${PUID}" abc

# -m chowns the home contents; this covers the directory itself in case a
# variant of usermod skips it.
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
