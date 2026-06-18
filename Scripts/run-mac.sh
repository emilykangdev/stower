#!/usr/bin/env bash
# Deterministic build-and-run for the StowerMac app.
#
# Why this exists: across a debugging session it is easy to run a binary that is
# older than your latest source edit ("I'm not seeing your changes"). This script
# rebuilds, prints the exact binary timestamp so you can confirm it is fresh, and
# launches THAT binary standalone (launchd, not under Xcode's debugger — which
# avoids TCC permission-attribution quirks). See Docs/Permissions.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="StowerMac/StowerMac.xcodeproj"
SCHEME="StowerMac"
CONFIG="Debug"

echo "==> Building $SCHEME ($CONFIG) from $REPO_ROOT"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'platform=macOS' build

APP="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')"

if [ ! -d "$APP" ]; then
  echo "ERROR: built app not found at: $APP" >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/StowerMac"
echo ""
echo "==> Built binary: $BIN"
echo "==> Binary built at: $(stat -f '%Sm' "$BIN")"
echo "==> Latest commit:  $(git log -1 --format='%cd %h %s' --date=local)"
echo ""
echo "==> Quitting any running copy and launching the fresh build standalone…"
pkill -x StowerMac 2>/dev/null || true
sleep 1
open "$APP"
echo "==> Launched. In the app: grant Full Disk Access if asked, then on the board"
echo "    click 'Show names' in the banner and Allow the Contacts prompt."
