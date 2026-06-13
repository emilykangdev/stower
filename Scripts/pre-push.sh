#!/usr/bin/env bash
# Pre-push hook: OPT-IN swift-signal-review before a branch goes up for a PR.
#
# By default this does nothing but print a one-line reminder. AGENTS.md says run
# the pattern pass "once per branch, when you are about to open a PR — not on
# every commit", but a pre-push hook fires on EVERY push (many times as you
# iterate), and each run is a slow, blocking headless LLM call. So the review is
# opt-in: set STOWER_SIGNAL_REVIEW_ON_PUSH=1 to run it on push, or just run it by
# hand at PR time — `./Scripts/signal-review.sh`. Either way it is advisory and
# NEVER blocks the push. The hard gate is precheck.sh (pre-commit + CI).
#
# Installed by Scripts/install-hooks.sh -> .git/hooks/pre-push.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "${STOWER_SIGNAL_REVIEW_ON_PUSH:-0}" != "1" ]; then
    echo "pre-push: skipping swift-signal-review (opt in with STOWER_SIGNAL_REVIEW_ON_PUSH=1," \
        "or run ./Scripts/signal-review.sh before opening the PR)."
    exit 0
fi

# Opt-in path. Still never blocks; skip where it can't or needn't run:
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
