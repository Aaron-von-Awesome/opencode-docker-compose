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

# Drop privileges and exec the CMD as the abc user
exec gosu abc "$@"
