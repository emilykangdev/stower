#!/usr/bin/env bash
# scripts/spawn-plan-worktrees.sh — fan a sprint's plans out into worktrees.
#
# The sprint flow: one worktree holds several plans (tmp/ready-plans/*.md);
# each plan should become its own worktree + branch off main so it can be
# built and shipped independently (one branch = one shippable unit, so
# /ship-with-codex never reviews a moving, multi-plan diff).
#
# This is the CREATE half. It composes with scripts/new-worktree.sh (the
# per-worktree env/vault bootstrap), which it runs inside each new worktree.
#
# Usage:
#   scripts/spawn-plan-worktrees.sh                 # one worktree per tmp/ready-plans/*.md
#   scripts/spawn-plan-worktrees.sh a.md b.md       # only these plan files
#   scripts/spawn-plan-worktrees.sh encryption ui   # bare names (no plan file needed)
#   scripts/spawn-plan-worktrees.sh --base origin/main --fetch --install
#
# Flags:
#   --base <ref>   Branch off this ref          (default: the repo's default branch)
#   --fetch        git fetch origin before branching
#   --install      run `npm install` in each new worktree (slow; off by default)
#   --dry-run      print what would happen, change nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- defaults ---------------------------------------------------------------
BASE=""
DO_FETCH=0
DO_INSTALL=0
DRY_RUN=0
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    [[ $# -ge 2 ]] || { echo "--base requires a ref" >&2; exit 2; }; BASE="$2"; shift 2 ;;
    --fetch)   DO_FETCH=1; shift ;;
    --install) DO_INSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*)        echo "Unknown flag: $1" >&2; exit 2 ;;
    *)         ARGS+=("$1"); shift ;;
  esac
done

# Default base = the repo's default branch (origin/HEAD), falling back to main.
if [[ -z "$BASE" ]]; then
  BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@origin/@')"
  [[ -z "$BASE" ]] && BASE="main"
fi

# Where plans live, first match wins.
PLANS_DIR=""
for d in tmp/ready-plans docs/ready-plans; do
  [[ -d "$d" ]] && { PLANS_DIR="$d"; break; }
done

# --- build the work list: (branch, optional-plan-file) pairs ----------------
# Each entry is "branch<TAB>planpath" (planpath empty if none).
declare -a JOBS=()

slugify() { # filename/string -> kebab branch name
  printf '%s' "$1" \
    | sed -E 's/\.md$//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}[-_]?//; s/^[0-9]+[-_.]//' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9._-' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//'
}

if [[ ${#ARGS[@]} -gt 0 ]]; then
  for a in "${ARGS[@]}"; do
    if [[ -f "$a" ]]; then
      JOBS+=("$(slugify "$(basename "$a")")"$'\t'"$a")
    else
      JOBS+=("$(slugify "$a")"$'\t')   # bare name, no plan file
    fi
  done
else
  [[ -n "$PLANS_DIR" ]] || { echo "No plans dir (tmp/ready-plans or docs/ready-plans) and no args given." >&2; exit 1; }
  shopt -s nullglob
  plans=("$PLANS_DIR"/*.md)
  shopt -u nullglob
  [[ ${#plans[@]} -gt 0 ]] || { echo "No *.md plans in $PLANS_DIR/ and no args given." >&2; exit 1; }
  for p in "${plans[@]}"; do
    JOBS+=("$(slugify "$(basename "$p")")"$'\t'"$p")
  done
fi

[[ $DO_FETCH -eq 1 && $DRY_RUN -eq 0 ]] && { echo "→ git fetch origin"; git fetch origin; }

echo "Base ref: $BASE"
echo "Spawning ${#JOBS[@]} worktree(s) under $REPO_ROOT/worktrees/"
echo

# --- create each worktree ---------------------------------------------------
created=0; skipped=0
for job in "${JOBS[@]}"; do
  branch="${job%%$'\t'*}"
  plan="${job#*$'\t'}"
  wt="worktrees/$branch"

  if [[ -z "$branch" ]]; then echo "✗ empty branch name, skipping"; continue; fi

  # Skip if the branch or the worktree path already exists — never clobber.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "• $branch — branch already exists, skipping"; ((skipped++)); continue
  fi
  if [[ -e "$wt" ]]; then
    echo "• $branch — $wt already exists, skipping"; ((skipped++)); continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  would: git worktree add $wt -b $branch $BASE"
    [[ -n "$plan" ]] && echo "         copy plan $plan -> $wt/tmp/ready-plans/"
    continue
  fi

  echo "→ $branch"
  git worktree add "$wt" -b "$branch" "$BASE" >/dev/null

  # Carry the plan into the new worktree (tmp/ is gitignored, so it won't
  # come across via the branch — copy it so work can start immediately).
  if [[ -n "$plan" ]]; then
    mkdir -p "$wt/tmp/ready-plans"
    cp "$plan" "$wt/tmp/ready-plans/"
    echo "  plan → $wt/tmp/ready-plans/$(basename "$plan")"
  fi

  # Per-worktree env/vault bootstrap, if this repo has it. Capture output to a
  # log instead of /dev/null so a failure leaves the actual error on disk —
  # the warning alone can't tell you WHY it failed.
  if [[ -f "$wt/scripts/new-worktree.sh" ]]; then
    ( cd "$wt" && bash scripts/new-worktree.sh ) > "$wt/.bootstrap.log" 2>&1 \
      && echo "  bootstrapped .env.local (vault-scoped)" \
      || echo "  ⚠ new-worktree.sh failed — see $wt/.bootstrap.log (or run it manually in $wt)"
  fi

  if [[ $DO_INSTALL -eq 1 && -f "$wt/package.json" ]]; then
    echo "  npm install …"
    ( cd "$wt" && npm install ) > "$wt/.npm-install.log" 2>&1 \
      && echo "  deps installed" \
      || echo "  ⚠ npm install failed — see $wt/.npm-install.log (or run it manually in $wt)"
  fi

  ((created++))
done

echo
echo "Done: $created created, $skipped skipped."
[[ $DO_INSTALL -eq 0 && $DRY_RUN -eq 0 && $created -gt 0 ]] && \
  echo "Tip: deps not installed (use --install). In a worktree: cd worktrees/<branch> && npm install"
echo
echo "List:   git worktree list"
echo "Enter:  cd worktrees/<branch>"
echo "Remove: git worktree remove worktrees/<branch> && git branch -D <branch>"
