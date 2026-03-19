#!/usr/bin/env python3
"""
init_repo.py
 
Initializes the OpenCode repository by copying configuration files
to the User’s OpenCode directory and updating the User’s shell rc file
with the repository’s aliases.
 
Author: VibeCoder von Awesome
"""

import os
import shutil
import re


def detect_shells():
    """Return a list of (shell_name, rc_path) for existing shell rc files."""
    home = os.path.expanduser("~")
    shells = []
    bash = os.path.join(home, ".bashrc")
    if os.path.exists(bash):
        shells.append(("bash", bash))
    zsh = os.path.join(home, ".zshrc")
    if os.path.exists(zsh):
        shells.append(("zsh", zsh))
    fish = os.path.join(home, ".config", "fish", "config.fish")
    if os.path.exists(fish):
        shells.append(("fish", fish))
    return shells


def prompt_shell_choice(shells):
    """Prompt the user to select one of the available shells."""
    if not shells:
        return None
    if len(shells) == 1:
        return shells[0][1]
    print("Detected the following shell configuration files:")
    for idx, (name, path) in enumerate(shells, 1):
        print(f"  {idx}. {name} ({path})")
    while True:
        choice = input(f"Choose shell to install aliases into [1-{len(shells)}]: ").strip()
        if choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(shells):
                return shells[idx - 1][1]
        print(f"Please enter a number between 1 and {len(shells)}.")

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


def update_shellrc(alias_file: str, rc_path: str):
    """
    Append aliases from alias_file to rc_path, replacing
    any alias with the same name.
    """
    # Read existing rc file (create if missing)
    if os.path.exists(rc_path):
        with open(rc_path, "r", encoding="utf-8") as f:
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
    with open(rc_path, "w", encoding="utf-8") as f:
        f.write("\n".join(new_bashrc) + "\n")

    print(f"Updated aliases in {rc_path}")


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

    # Update shell rc file
    # Detect available shells and prompt user
    shells = detect_shells()
    chosen_rc_path = prompt_shell_choice(shells)

    # If no shell detected, fall back to default ~/.bashrc
    if not chosen_rc_path:
        chosen_rc_path = os.path.expanduser("~/.bashrc")
        print("No shell rc file detected. Creating ~/.bashrc.")
        open(chosen_rc_path, "a").close()

    update_shellrc(bash_aliases, chosen_rc_path)

    print("Repository initialized successfully.")


if __name__ == "__main__":
    main()
