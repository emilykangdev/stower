#!/usr/bin/env bash
# pre-pr: open the PR (if needed), then fire swift-signal-review on the branch.
#
# This replaces the old per-push hook. A push happens many times per branch; a
# PR happens once — and AGENTS.md says run the pattern pass "once per branch,
# when you are about to open a PR", not on every push. So the review fires HERE,
# at the PR boundary, scoped to the PR's base branch. Advisory: it prints
# judgment-level findings and NEVER blocks. The hard gate is precheck.sh
# (pre-commit + CI).
#
# Usage:
#   Scripts/pre-pr.sh [gh pr create args...]    # e.g. --base stower-core --fill
# Run it when you open the PR; re-run anytime to re-review the branch.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

base_ref="origin/main"

if command -v gh >/dev/null 2>&1; then
    if gh pr view --json number >/dev/null 2>&1; then
        echo "pre-pr: PR already open for this branch."
    elif [ "$#" -gt 0 ]; then
        echo "pre-pr: opening PR (gh pr create $*) ..."
        gh pr create "$@" || echo "pre-pr: gh pr create failed — open it manually, then re-run." >&2
    else
        echo "pre-pr: no PR open and no gh args given — reviewing only (open the PR yourself)."
    fi
    # Scope the review to the PR's base branch when it can be resolved.
    if pr_base=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null) && [ -n "$pr_base" ]; then
        base_ref="origin/$pr_base"
    fi
else
    echo "pre-pr: gh not on PATH — skipping PR creation; running the review only." >&2
fi

# Fire the review. Skip where it can't or needn't run:
#   - claude not on PATH (no way to run the headless review)
#   - no Swift changed vs the base (nothing to review; doc-only branches skip it)
if ! command -v claude >/dev/null 2>&1; then
    echo "pre-pr: claude not on PATH — skipping swift-signal-review." >&2
    exit 0
fi
if ! git diff "$base_ref"... --name-only 2>/dev/null | grep -q '\.swift$'; then
    echo "pre-pr: no Swift changes vs $base_ref — skipping swift-signal-review."
    exit 0
fi

echo "--- pre-pr: swift-signal-review vs $base_ref (advisory; does NOT block) ---"
./Scripts/signal-review.sh "$base_ref" || true
exit 0
