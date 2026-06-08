#!/usr/bin/env bash
# Single-command gate. Run before every commit.
# Scripts/install-hooks.sh wires this to .git/hooks/pre-commit.
# Covers the same paths as .swiftlint.yml `included:` — Sources Tests.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Step 1 — swift-format. FAILS if absent (not a skip).
# Prefer a swift-format on PATH; fall back to the one bundled with the active
# Swift toolchain (Swift 6 ships swift-format), which is not always on PATH.
if command -v swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT=swift-format
elif SWIFT_FORMAT="$(xcrun --find swift-format 2>/dev/null)" && [ -x "$SWIFT_FORMAT" ]; then
    :
else
    echo "ERROR: swift-format not found. It ships with the Swift 6 toolchain;" >&2
    echo "       ensure your toolchain is on PATH, or: brew install swift-format" >&2
    exit 1
fi
"$SWIFT_FORMAT" lint --strict --recursive Sources Tests

# Step 2 — swiftlint. FAILS if absent (not a skip).
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "ERROR: swiftlint not installed. Install a precompiled binary from" >&2
    echo "       https://github.com/realm/SwiftLint/releases (portable_swiftlint.zip)" >&2
    echo "       or, with full Xcode: brew install swiftlint" >&2
    exit 1
fi
# A precompiled SwiftLint needs sourcekitdInProc.framework. Full Xcode wires it
# automatically; under Command Line Tools, point DYLD at the CLT framework dir
# so SourceKit loads (otherwise swiftlint fatal-errors loading sourcekitdInProc).
DEVDIR="$(xcode-select -p)"
if [ "$(basename "$DEVDIR")" = "CommandLineTools" ]; then
    DYLD_FRAMEWORK_PATH="$DEVDIR/usr/lib" swiftlint lint --strict
else
    swiftlint lint --strict
fi

# Step 3 — build.
swift build

# Step 4 — test.
# Swift Testing needs Testing.framework. Full Xcode wires it automatically; the
# Command Line Tools do not, so `swift test` reports "no such module 'Testing'".
# When running under CLT, derive the framework search/rpath flags from the
# active developer dir so the gate actually runs. With full Xcode installed,
# DEVDIR basename is "Developer" and we run plain `swift test`.
DEVDIR="$(xcode-select -p)"
if [ "$(basename "$DEVDIR")" = "CommandLineTools" ]; then
    FW="$DEVDIR/Library/Developer/Frameworks"
    INTEROP="$DEVDIR/Library/Developer/usr/lib"
    swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$INTEROP"
else
    swift test
fi

# Step 5 — module boundary checks.
# Match only real Swift import declarations (anchored to line start, optional
# @testable), and only in *.swift files — so a README, comment, or string that
# mentions "import StowerMessages" cannot trip a false-positive failure.
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(StowerPhotos|StowerMessages)([[:space:]]|\.|$)' Sources/StowerCore/ 2>/dev/null; then
    echo "ERROR: StowerCore must not import StowerPhotos or StowerMessages" >&2
    exit 1
fi
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+StowerMessages([[:space:]]|\.|$)' Sources/StowerPhotos/ 2>/dev/null; then
    echo "ERROR: StowerPhotos must not import StowerMessages" >&2
    exit 1
fi
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+StowerPhotos([[:space:]]|\.|$)' Sources/StowerMessages/ 2>/dev/null; then
    echo "ERROR: StowerMessages must not import StowerPhotos" >&2
    exit 1
fi
