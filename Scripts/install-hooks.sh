#!/usr/bin/env bash
set -euo pipefail
# Wire Stower's git hooks. Uses git rev-parse so this works in both regular clones
# and git worktrees (in a worktree, .git is a pointer file — the hooks dir is
# elsewhere).
# NOTE: --git-common-dir installs the hooks for ALL worktrees in this repo. The
# symlinks point to THIS worktree's Scripts/. If you later remove this worktree,
# the hooks break for others — re-run install-hooks.sh from any remaining worktree.
#
# Installs:
#   pre-commit -> Scripts/precheck.sh   (the hard mechanical gate, every commit)
# The advisory swift-signal-review is NOT a git hook — a push happens many times
# per branch, a PR once. Run it at PR time with Scripts/pre-pr.sh.
HOOK_DIR="$(git rev-parse --git-common-dir)/hooks"
ROOT="$(git rev-parse --show-toplevel)"
mkdir -p "$HOOK_DIR"

install_hook() {
    local name="$1" target="$2" hook="$HOOK_DIR/$1"

    # Idempotent: our symlink is already in place.
    if [ -L "$hook" ] && [ "$(readlink "$hook")" = "$target" ]; then
        echo "$name hook already installed (-> ${target#"$ROOT"/})."
        return 0
    fi

    # Never clobber a hook we did not install — that would silently drop whatever
    # checks it performed. Refuse with instructions instead (use -e || -L so a
    # broken symlink is caught too).
    if [ -e "$hook" ] || [ -L "$hook" ]; then
        {
            echo "ERROR: a $name hook already exists and was not installed by Stower:"
            echo "         $hook"
            echo "Refusing to overwrite it. Either back it up and remove it:"
            echo "        mv \"$hook\" \"$hook.bak\""
            echo "  or chain it from your existing hook by adding this line:"
            echo "        \"$target\""
            echo "Then re-run Scripts/install-hooks.sh."
        } >&2
        return 1
    fi

    ln -s "$target" "$hook"
    echo "$name hook installed (-> ${target#"$ROOT"/})."
}

# Remove the legacy pre-push signal-review hook if a previous install left one
# (the review moved to the PR-time Scripts/pre-pr.sh). Only our own symlink is
# touched — a hook we did not install is left alone.
legacy_pre_push="$HOOK_DIR/pre-push"
if [ -L "$legacy_pre_push" ]; then
    case "$(readlink "$legacy_pre_push")" in
    */Scripts/pre-push.sh)
        rm -f "$legacy_pre_push"
        echo "removed legacy pre-push hook (signal-review now runs via Scripts/pre-pr.sh)."
        ;;
    esac
fi

rc=0
install_hook pre-commit "$ROOT/Scripts/precheck.sh" || rc=1
exit "$rc"
