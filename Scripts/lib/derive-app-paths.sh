#!/usr/bin/env bash
# Shared helper for Scripts/run-app.sh and Scripts/run-app-demo.sh: build the
# StowerMac app and derive the built bundle path, executable/process name, and
# binary path from a SINGLE `xcodebuild -showBuildSettings` call.
#
# Source this file, then call `stower_build_and_derive_paths <project> <scheme>
# <config>`. On success it sets three variables in the caller's shell:
#   APP             — the built .app bundle (e.g. …/Debug/StowerTest.app)
#   EXECUTABLE_NAME — the Mach-O / process name (e.g. StowerTest), for `pkill -x`
#   BIN             — the executable inside the bundle (…/Contents/MacOS/<name>)
# It `exit`s non-zero with a specific message if the build product or executable
# is missing, so callers don't repeat those guards. (Sourced, so `exit` ends the
# caller — that is the intended fail-fast under the caller's `set -euo pipefail`.)
#
# Why derive instead of hardcode: the Debug product is "StowerTest" and Release is
# "Stower"; deriving EXECUTABLE_NAME from -showBuildSettings survives any future
# PRODUCT_NAME change with zero script edits. See Docs/Permissions.md and the
# 2026-07-03 app-identity plan (JC5). Extracting this once keeps the two run
# scripts from drifting (one commit, one concern — AGENTS.md).

# Usage: stower_build_and_derive_paths <project> <scheme> <config>
# Sets APP, EXECUTABLE_NAME, BIN on success; exits non-zero on failure.
stower_build_and_derive_paths() {
  local project="$1" scheme="$2" config="$3"

  echo "==> Building $scheme ($config) from $PWD"
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$config" \
    -destination 'platform=macOS' build

  # Capture -showBuildSettings ONCE, then derive both the app path and the
  # executable/process name from that same text — never re-run xcodebuild.
  local settings
  settings="$(xcodebuild -project "$project" -scheme "$scheme" -configuration "$config" \
    -showBuildSettings 2>/dev/null)"

  # Split on ' = ' (not $3) so a future space-containing value wouldn't truncate.
  APP="$(printf '%s\n' "$settings" | awk -F ' = ' '/ BUILT_PRODUCTS_DIR = /{d=$2} / FULL_PRODUCT_NAME = /{n=$2} END{print d"/"n}')"
  EXECUTABLE_NAME="$(printf '%s\n' "$settings" | awk -F ' = ' '/ EXECUTABLE_NAME = /{print $2; exit}')"

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
}
