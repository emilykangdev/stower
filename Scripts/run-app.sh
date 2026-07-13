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

# shellcheck source=Scripts/lib/derive-app-paths.sh
source "$REPO_ROOT/Scripts/lib/derive-app-paths.sh"

PROJECT="StowerMac/StowerMac.xcodeproj"
SCHEME="StowerMac"
CONFIG="Debug"

# Builds, then sets APP / EXECUTABLE_NAME / BIN (or exits with a specific error).
stower_build_and_derive_paths "$PROJECT" "$SCHEME" "$CONFIG"

echo ""
echo "==> Built binary: $BIN"
echo "==> Binary built at: $(stat -f '%Sm' "$BIN")"
echo "==> Latest commit:  $(git log -1 --format='%cd %h %s' --date=local)"
echo ""
echo "==> Quitting any running copy and launching the fresh build standalone…"
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
sleep 1
open "$APP"
echo "==> Launched. In the app: if asked, select your Messages folder in the picker"
echo "    that opens, then on the board click 'Show names' in the banner and Allow"
echo "    the Contacts prompt."
