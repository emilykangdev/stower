#!/usr/bin/env bash
# Pre-push hook: run swift-signal-review on the branch before it goes up for a PR.
#
# This is the "before PR" moment — `git push` is what you do right before opening
# a PR, and it fires once per push (not once per commit). Advisory: it surfaces
# judgment-level bad patterns so you catch them before the PR, but it NEVER blocks
# the push. signal-review produces findings, not pass/fail, and a slow LLM call
# shouldn't gate `git push`. The hard gate is precheck.sh (pre-commit + CI).
#
# Installed by Scripts/install-hooks.sh -> .git/hooks/pre-push.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# Always exit 0 — never block the push. Skip where it can't or needn't run:
#   - claude not on PATH (no way to run the headless review)
#   - no Swift changed vs origin/main (nothing to review; doc-only branches skip it)
if ! command -v claude >/dev/null 2>&1; then
    echo "pre-push: claude not on PATH — skipping swift-signal-review." >&2
    exit 0
fi
if ! git diff origin/main... --name-only 2>/dev/null | grep -q '\.swift$'; then
    echo "pre-push: no Swift changes vs origin/main — skipping swift-signal-review."
    exit 0
fi

echo "--- pre-push: swift-signal-review (advisory; does NOT block the push) ---"
./Scripts/signal-review.sh || true
exit 0
