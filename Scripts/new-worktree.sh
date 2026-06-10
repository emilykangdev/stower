#!/usr/bin/env bash
# Bootstrap a freshly-created git worktree (or clone) so it is ready to build,
# test, and commit. Idempotent — safe to re-run.
#
# Conductor spins up many worktrees; each one needs its dependencies resolved and
# the pre-commit hook wired. This is the Swift/SPM analog of "npm install + husky
# install" — there is no npm or husky here (the project is Swift Package Manager):
#   - "npm install"   -> swift package resolve    (fetch deps pinned in Package.resolved)
#   - "husky install" -> Scripts/install-hooks.sh  (wire precheck.sh to pre-commit)
#
# Usage:  ./Scripts/new-worktree.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "==> Resolving Swift package dependencies (swift package resolve)..."
# `resolve` fetches the versions already pinned in Package.resolved; it does not
# bump them. (To intentionally update, use `swift package update` — never edit
# Package.resolved by hand. See AGENTS.md.)
swift package resolve

echo "==> Installing git hooks: pre-commit (precheck) + pre-push (signal-review)..."
./Scripts/install-hooks.sh

echo "==> Checking lint tools required by Scripts/precheck.sh..."
missing=0
if command -v swift-format >/dev/null 2>&1 || xcrun --find swift-format >/dev/null 2>&1; then
    echo "    swift-format: found"
else
    echo "    swift-format: MISSING — 'brew install swift-format' (ships with the Swift 6 toolchain too)"
    missing=1
fi
if command -v swiftlint >/dev/null 2>&1; then
    echo "    swiftlint: found"
else
    echo "    swiftlint: MISSING — 'brew install swiftlint' or a precompiled release binary"
    missing=1
fi

echo
if [ "$missing" -ne 0 ]; then
    # Fail loudly: a worktree without the lint tools is not actually ready — the
    # pre-commit gate (precheck.sh) will hard-fail on the first commit. Surface
    # the requirement now rather than at commit time.
    echo "ERROR: worktree set up, but install the missing lint tool(s) above before committing." >&2
    exit 1
fi

echo "Worktree ready. Run ./Scripts/precheck.sh to verify the full gate."
