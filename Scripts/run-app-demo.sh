#!/usr/bin/env bash
# Build-and-run StowerMac against the DEMO Messages database, never the real one.
#
# The app reads its board from `~/Library/Messages/chat.db` by default. This script
# instead points a DEBUG build at the curated demo database via the DEBUG-only
# `STOWER_MESSAGES_DB` override (see StowerMessagesSourceOverride), so the
# relationship-debt board can be demoed/recorded WITHOUT swapping — and risking —
# your real Messages history.
#
# Unlike run-app.sh (which uses `open`, whose launchd path does not forward env
# vars), this launches the built binary directly so the env override reaches the
# app. The demo db lives under Application Support, which needs no Full Disk Access,
# so the direct launch raises no TCC/FDA prompt.
#
# By default it regenerates the demo db first so its dates stay inside the board's
# in-window gates (>3 days old, <60-day reciprocity window) no matter when you run
# it. Pass --no-regen to launch against the existing file unchanged.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="StowerMac/StowerMac.xcodeproj"
SCHEME="StowerMac"
CONFIG="Debug"
DEMO_DB="$HOME/Library/Application Support/Stower/DemoData/chat.db"

REGEN=1
if [ "${1:-}" = "--no-regen" ]; then
  REGEN=0
fi

if [ "$REGEN" -eq 1 ]; then
  echo "==> Regenerating demo db (fresh in-window dates): $DEMO_DB"
  python3 "$REPO_ROOT/Scripts/generate-demo-db.py"
elif [ ! -f "$DEMO_DB" ]; then
  echo "ERROR: demo db not found at: $DEMO_DB" >&2
  echo "       Run without --no-regen, or: python3 Scripts/generate-demo-db.py" >&2
  exit 1
fi

echo "==> Building $SCHEME ($CONFIG) from $REPO_ROOT"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'platform=macOS' build

# Capture -showBuildSettings ONCE, then derive both the app path and the
# executable/process name from that same text — never re-run xcodebuild.
SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null)"

# Split on ' = ' (not $3) so a future space-containing value wouldn't truncate.
APP="$(printf '%s\n' "$SETTINGS" | awk -F ' = ' '/ BUILT_PRODUCTS_DIR = /{d=$2} / FULL_PRODUCT_NAME = /{n=$2} END{print d"/"n}')"
EXECUTABLE_NAME="$(printf '%s\n' "$SETTINGS" | awk -F ' = ' '/ EXECUTABLE_NAME = /{print $2; exit}')"

if [ ! -d "$APP" ]; then
  echo "ERROR: built app not found at: $APP" >&2
  exit 1
fi

if [ -z "$EXECUTABLE_NAME" ]; then
  echo "ERROR: could not derive EXECUTABLE_NAME from -showBuildSettings" >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/$EXECUTABLE_NAME"

if [ ! -x "$BIN" ]; then
  echo "ERROR: executable missing: $BIN" >&2
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
