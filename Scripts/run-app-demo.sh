#!/usr/bin/env bash
# Build-and-run StowerMac against the DEMO Messages database, never the real one.
#
# The app reads its board from a security-scoped bookmark by default. This script
# instead points a DEBUG build at the curated demo database via the DEBUG-only
# `STOWER_MESSAGES_DB` override (see StowerMessagesSourceOverride), so the
# relationship-debt board can be demoed/recorded WITHOUT swapping — and risking —
# your real Messages history.
#
# Unlike run-app.sh (which uses `open`, whose launchd path does not forward env
# vars), this launches the built binary directly so the env override reaches the
# app. Under App Sandbox (ENABLE_APP_SANDBOX=YES), the sandboxed process's own
# Application Support redirects into its container
# (~/Library/Containers/<bundle-id>/Data/Library/Application Support/) regardless
# of how the binary is launched — a literal unsandboxed-`$HOME` path computed in
# this script's shell would point outside the app's reachable region entirely, so
# DEMO_DB is computed container-relative below (derived the same way
# Scripts/lib/derive-app-paths.sh derives the built binary's other paths). The demo
# db needs no Messages access grant at all, so the direct launch raises no prompt.
#
# By default it regenerates the demo db first so its dates stay inside the board's
# in-window gates (>3 days old, <60-day reciprocity window) no matter when you run
# it. Pass --no-regen to launch against the existing file unchanged.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=Scripts/lib/derive-app-paths.sh
source "$REPO_ROOT/Scripts/lib/derive-app-paths.sh"

PROJECT="StowerMac/StowerMac.xcodeproj"
SCHEME="StowerMac"
CONFIG="Debug"

REGEN=1
if [ "${1:-}" = "--no-regen" ]; then
  REGEN=0
fi

# Builds, then sets APP / EXECUTABLE_NAME / BIN / BUNDLE_ID (or exits with a
# specific error). BUNDLE_ID must be known BEFORE computing DEMO_DB, since the
# sandboxed container path is keyed by it.
stower_build_and_derive_paths "$PROJECT" "$SCHEME" "$CONFIG"

DEMO_DB="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/Stower/DemoData/chat.db"

if [ "$REGEN" -eq 1 ]; then
  echo "==> Regenerating demo db (fresh in-window dates): $DEMO_DB"
  python3 "$REPO_ROOT/Scripts/generate-demo-db.py" --output "$DEMO_DB"
elif [ ! -f "$DEMO_DB" ]; then
  echo "ERROR: demo db not found at: $DEMO_DB" >&2
  echo "       Run without --no-regen, or: python3 Scripts/generate-demo-db.py --output \"$DEMO_DB\"" >&2
  exit 1
fi

echo ""
echo "==> Built binary: $BIN"
echo "==> Binary built at: $(stat -f '%Sm' "$BIN")"
echo "==> Demo source:   $DEMO_DB"
echo ""
echo "==> Quitting any running copy and launching the fresh build against the demo db…"
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
sleep 1
STOWER_MESSAGES_DB="$DEMO_DB" "$BIN" &
echo "==> Launched against the demo db (your real Messages history is untouched)."
echo "    Names come from Contacts, so the 555-01xx demo numbers show as numbers"
echo "    unless you've added them as contacts."
