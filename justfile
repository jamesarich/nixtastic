# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# Thin aliases over the flake apps — `just` ships in every dev shell, so
# these work anywhere in the workspace. The flake apps remain the real
# interface; nothing here does anything `nix run` cannot.

# List the recipes.
default:
    @just --list

# Fetch all repos and report drift (read-only for git).
sync *ARGS:
    nix run .#sync -- {{ ARGS }}

# Fast-forward every repo that safely can be.
pull:
    nix run .#sync -- --pull

# Orient before touching a repo: branch, shell, docs to read, PRs.
#
# [no-cd] because just otherwise runs recipes from the justfile's directory,
# and brief answers about the checkout you are STANDING in — cd'ing to the
# root would make `just brief` report the primary checkout while you sit in a
# worktree, which is the exact failure the tool exists to prevent. Keeping the
# caller's cwd then costs the short `.#` ref (it cannot cross a git-repo
# boundary), so name the flake by its absolute path.
[no-cd]
brief repo:
    nix run {{ justfile_directory() }}#brief -- {{ repo }}

# Worktrees: `just worktree android fix/thing`, `--list`, `--remove`, `--prune`.
worktree *ARGS:
    nix run .#worktree -- {{ ARGS }}

# Check the wiring that fails silently.
doctor:
    nix run .#doctor

# Reconcile the Android SDK against android-sdk-packages.txt.
sdk:
    nix run .#bootstrap-sdk

# The full gate CI runs: eval everything, build this system's checks.
check:
    nix flake check --all-systems --no-build
    nix flake check

# Format the workspace's own .nix files.
fmt:
    nix fmt
