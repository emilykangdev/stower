#!/usr/bin/env bash
set -euo pipefail
# Use git rev-parse so this works in both regular clones and git worktrees.
# (In a worktree, .git is a pointer file — the hooks dir is elsewhere.)
# NOTE: --git-common-dir installs the hook for ALL worktrees in this repo.
# The symlink points to this worktree's Scripts/precheck.sh. If you later
# remove this worktree, the hook will break for other worktrees. Re-run
# install-hooks.sh from any remaining worktree to fix.
HOOK_DIR="$(git rev-parse --git-common-dir)/hooks"
PRECHECK="$(git rev-parse --show-toplevel)/Scripts/precheck.sh"
HOOK="$HOOK_DIR/pre-commit"
mkdir -p "$HOOK_DIR"

# Idempotent: if our symlink is already installed, do nothing.
if [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$PRECHECK" ]; then
    echo "Pre-commit hook already installed (-> Scripts/precheck.sh)."
    exit 0
fi

# Never clobber a pre-existing hook we did not install — doing so silently
# drops whatever checks the contributor's hook performed. Refuse with
# instructions instead (use -e || -L so broken symlinks are caught too).
if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
    {
        echo "ERROR: a pre-commit hook already exists and was not installed by Stower:"
        echo "         $HOOK"
        echo "Refusing to overwrite it. To use Stower's precheck hook, either:"
        echo "  - back up and remove the existing hook:"
        echo "        mv \"$HOOK\" \"$HOOK.bak\""
        echo "  - or chain precheck.sh from your existing hook by adding this line to it:"
        echo "        \"$PRECHECK\""
        echo "Then re-run Scripts/install-hooks.sh."
    } >&2
    exit 1
fi

ln -s "$PRECHECK" "$HOOK"
echo "Pre-commit hook installed."
