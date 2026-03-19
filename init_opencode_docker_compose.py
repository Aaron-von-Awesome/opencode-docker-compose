#!/usr/bin/env python3
"""
init_repo.py

Initializes the OpenCode repository by copying configuration files
to the User’s OpenCode directory and updating the User’s
~/.bashrc with the repository’s bash aliases.

Author: VibeCoder von Awesome
"""

import os
import shutil
import re
import sys


def confirm(prompt: str) -> bool:
    """Ask the user for a yes/no response."""
    while True:
        ans = input(f"{prompt} [y/n]: ").strip().lower()
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("Please answer 'y' or 'n'.")


def copy_file(src: str, dest_dir: str, dest_name: str | None = None):
    """Copy a file, preserving metadata."""
    if dest_name is None:
        dest_name = os.path.basename(src)
    dest_path = os.path.join(dest_dir, dest_name)
    shutil.copy2(src, dest_path)
    print(f"Copied {src} → {dest_path}")


def update_bashrc(alias_file: str, bashrc_path: str):
    """
    Append aliases from alias_file to bashrc_path, replacing
    any alias with the same name.
    """
    # Read existing bashrc (create if missing)
    if os.path.exists(bashrc_path):
        with open(bashrc_path, "r", encoding="utf-8") as f:
            bashrc_lines = f.readlines()
    else:
        bashrc_lines = []

    # Build a map of alias names to definitions from alias_file
    alias_defs = {}
    alias_pattern = re.compile(r"^alias\s+([\w-]+)=['\"](.+)['\"]\s*$")
    with open(alias_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            m = alias_pattern.match(line)
            if m:
                name, cmd = m.groups()
                alias_defs[name] = f"alias {name}='{cmd}'"

    # Remove existing aliases that are in alias_defs
    new_bashrc = []
    for line in bashrc_lines:
        m = alias_pattern.match(line.rstrip("\n"))
        if m and m.group(1) in alias_defs:
            continue  # skip to replace
        new_bashrc.append(line.rstrip("\n"))

    # Append the new aliases
    new_bashrc.extend(alias_defs.values())

    # Write back
    with open(bashrc_path, "w", encoding="utf-8") as f:
        f.write("\n".join(new_bashrc) + "\n")

    print(f"Updated aliases in {bashrc_path}")


def main():
    # Resolve absolute paths
    repo_root = os.path.abspath(os.path.dirname(__file__))
    docker_compose = os.path.join(repo_root, "docker-compose.opencode.yaml")
    opencode_jsonc = os.path.join(repo_root, "opencode.jsonc")
    bash_aliases = os.path.join(repo_root, "bash-aliases.txt")

    target_oc_dir = os.path.expanduser("~/OpenCode")
    target_container_dir = os.path.expanduser("~/OpenCode/opencode-container")

    # Check/create target directory
    if not os.path.isdir(target_oc_dir):
        print(f"Target directory does not exist: {target_oc_dir}")
        if not confirm("Create it?"):
            print("Aborting.")
            sys.exit(0)
        os.makedirs(target_oc_dir, exist_ok=True)
        os.makedirs(target_container_dir, exist_ok=True)
        print(f"Created {target_oc_dir}")
        print(f"Created {target_container_dir}")

    # Copy configuration files
    copy_file(docker_compose, target_oc_dir)
    copy_file(opencode_jsonc, target_oc_dir)

    # Update ~/.bashrc
    bashrc_path = os.path.expanduser("~/.bashrc")
    update_bashrc(bash_aliases, bashrc_path)

    print("Repository initialized successfully.")


if __name__ == "__main__":
    main()
