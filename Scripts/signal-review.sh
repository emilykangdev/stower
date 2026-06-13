#!/usr/bin/env bash
# Fire a fresh-context swift-signal-review against the current worktree's changes.
# Read-only; never modifies files. Uses the Claude Code CLI in headless (-p) mode
# under your existing plan — no API key required.
#
# The skill lives at .claude/skills/swift-signal-review/SKILL.md and is appended to
# the system prompt. The bad->good catalog (.claude/skills/SWIFT_PATTERNS.md) is the
# single source of truth; the model Reads it during the review.
#
# This is an on-demand / PR-time audit, NOT a per-commit hook. The mechanical gate
# (Scripts/precheck.sh) is what runs on every commit; the judgment review runs once
# per branch when you are about to open a PR (see AGENTS.md). Run it yourself with:
#   ./Scripts/signal-review.sh            # review this branch vs origin/main
#   ./Scripts/signal-review.sh main       # review vs a different base ref

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SKILL="$REPO_ROOT/.claude/skills/swift-signal-review/SKILL.md"
BASE_REF="${1:-origin/main}"

if [ ! -f "$SKILL" ]; then
    echo "Skill not found: $SKILL" >&2
    echo "Expected swift-signal-review at .claude/skills/swift-signal-review/SKILL.md" >&2
    exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
    echo "claude CLI not on PATH" >&2
    echo "Install Claude Code, then re-run." >&2
    exit 1
fi

# CWD intentionally NOT changed — claude inherits this shell's pwd so the review
# scopes to whichever worktree you invoked from.
#
# Pin the model explicitly: a headless `claude -p` otherwise inherits the user's
# configured default (e.g. an unavailable `claude-fable-5[1m]`) and aborts. Any
# capable model works for an advisory review; override with SIGNAL_REVIEW_MODEL.
claude -p --model "${SIGNAL_REVIEW_MODEL:-sonnet}" "$(cat <<EOF
Run swift-signal-review against the current git working state in this directory,
following the skill in your system prompt. The bad->good pattern catalog is
.claude/skills/SWIFT_PATTERNS.md — Read it first; it is the single source of truth.

Scope:
- Changed Swift files only (.swift). Enumerate with:
    git diff --cached
    git diff
    git diff ${BASE_REF}...
    git ls-files --others --exclude-standard
- Review the change, not the whole tree. (Repo-wide cleanup is swift-pattern-sweep.)

Read-only — do not modify any files.

Output, one line per finding:
  [SEVERITY] <file>:<line> — [catalog #n | outside catalog] <issue> — <fix> — recurs: <1x | Nx>

Severity ladder:
- MUST-FIX = a gate would fail, OR a reject-on-sight item (unexpected loop,
  functionality nobody asked for, a test weakened/skipped/deleted to pass, real
  Photos/Messages data in fixtures/logs), OR a clearly-wrong judgment pattern.
- CONSIDER = a judgment pattern worth fixing.
- INFO     = noted for awareness.

For any pattern that recurs (>=2x — present in this change AND elsewhere in the
repo), state its catalog Sweep-able flag and recommend the next skill:
swift-pattern-sweep if Sweep-able: yes, otherwise harden-guardrail.

End with one summary line: "N must-fix, N consider, N info." If zero: "No findings."

Do NOT flag formatting, lint, build, type errors, or missing tests — precheck.sh
owns those. Focus only on the catalog patterns and the Stower architecture rules.
EOF
)" --append-system-prompt "$(cat "$SKILL")"
