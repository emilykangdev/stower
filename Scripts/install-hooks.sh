#!/usr/bin/env bash
set -euo pipefail
# Use git rev-parse so this works in both regular clones and git worktrees.
# (In a worktree, .git is a pointer file — the hooks dir is elsewhere.)
# NOTE: --git-common-dir installs the hook for ALL worktrees in this repo.
# The symlink points to this worktree's Scripts/precheck.sh. If you later
# remove this worktree, the hook will break for other worktrees. Re-run
# install-hooks.sh from any remaining worktree to fix.
HOOK_DIR="$(git rev-parse --git-common-dir)/hooks"
mkdir -p "$HOOK_DIR"
ln -sf "$(git rev-parse --show-toplevel)/Scripts/precheck.sh" "$HOOK_DIR/pre-commit"
echo "Pre-commit hook installed."
