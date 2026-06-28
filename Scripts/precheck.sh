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
#
# The FoundationModels integration suite exercises the REAL on-device model and
# requires macOS 26 + Apple Intelligence. By the no-skip rule it FAILS LOUDLY
# (never skip-passes) when that prerequisite is absent — correct on a dev
# machine, but a *permanent* red on a CI runner that physically cannot run
# FoundationModels (GitHub's macos-15 tops out below macOS 26). A gate that can
# never go green gives no signal, so CI sets STOWER_SKIP_FM_INTEGRATION=1 to
# exclude ONLY that suite; every other test stays fail-hard. The var is unset
# locally, so on the macOS 26 dev machine the suite runs for real and the
# no-skip rule still holds — this is not the forbidden skip-on-missing-config,
# it only drops a suite the CI hardware can never satisfy.
SKIP_ARGS=()
if [ "${STOWER_SKIP_FM_INTEGRATION:-}" = "1" ]; then
    echo "NOTE: STOWER_SKIP_FM_INTEGRATION=1 — excluding the FoundationModels" >&2
    echo "      integration suite (needs macOS 26 + Apple Intelligence). All" >&2
    echo "      other tests still run and still fail hard." >&2
    SKIP_ARGS=(--skip 'StowerFMReplyJudgeIntegrationTests')
fi

DEVDIR="$(xcode-select -p)"
if [ "$(basename "$DEVDIR")" = "CommandLineTools" ]; then
    FW="$DEVDIR/Library/Developer/Frameworks"
    INTEROP="$DEVDIR/Library/Developer/usr/lib"
    swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$INTEROP" \
        ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}
else
    swift test ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}
fi

# Step 4c — Deno unit tests for the licensing code (hermetic: fake fetch, no
# network/disk/env). Two homes: the license Edge Function (mint/webhook
# idempotency, signature, replay) in supabase/functions/license/index.test.ts, and
# the Keygen bootstrap script (exact-attribute drift checks) in
# Scripts/Keygen/bootstrap-keygen.test.ts. The real-CE integration tier
# (Scripts/Keygen/integration) needs the Docker harness and runs only in CI.
# FAILS if Deno is absent (not a skip): these guard the payment/license path, so
# "Deno missing" must break the gate loudly, never silently drop coverage.
if ! command -v deno >/dev/null 2>&1; then
    echo "ERROR: deno not installed — the license Edge Function tests cannot run" >&2
    echo "       and the payment/license invariants would ship unverified. Install:" >&2
    echo "       https://docs.deno.com/runtime/getting_started/installation/ (or: brew install deno)" >&2
    exit 1
fi
( cd supabase/functions/license && deno test )
( cd Scripts/Keygen && deno test )

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

# Step 6 — StowerMac app/UI boundary guards (FDA onboarding slice).
# These greps deliberately also cover StowerMac/StowerMac (the Xcode app's Swift
# sources) even though the format/lint steps above only target Sources/Tests —
# the boundary must hold in the app entry too. Standing gate; do not weaken to go
# green (AGENTS.md). Authored via /harden-guardrail.

# ── Static source guards (6x family) ─────────────────────────────────────────
# Each 6x check asserts a textual/structural fact about the source tree and fails
# loudly (echo ERROR >&2; exit 1) — a gate-time alternative to a unit test for
# "X is/isn't present, here." Add new ones as members, not a new mechanism.
#   tool:     grep (grep -RInE) for line-local facts; awk for region/block-scoped
#             facts ("only inside #if DEBUG", "only inside a Release config block").
#   polarity: must-be-absent → a match fails; must-be-present → a no-match fails.
#   deps:     none (no plutil/jq/python) — runs every commit.
# See AGENTS.md "Static source guards" for the rule.

# 6a — Engine-INTERNAL modules are NEVER imported by StowerMacUI (permanent ban,
#      incl. the adapter). The app sees value types + two actors, never GRDB/FM/Photos.
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(GRDB|FoundationModels|Photos|PhotoKit)([[:space:]]|$)' Sources/StowerMacUI/ 2>/dev/null; then
    echo "ERROR: StowerMacUI must not import an engine-internal module (GRDB/FoundationModels/Photos/PhotoKit)" >&2
    exit 1
fi

# 6b — StowerMessages may be imported by EXACTLY the four engine-coupled files: the
#      startup adapter, the board adapter, the shared composition, and the shared
#      engine->app mapping. Closed allowlist (do not weaken/delete to go green);
#      compared as a SORTED SET so file order/addition can't slip past the gate.
SM_ALLOWED="$(printf '%s\n' \
    "Sources/StowerMacUI/Startup/StowerMessagesStartupAdapter.swift" \
    "Sources/StowerMacUI/Board/StowerLiveBoardDataSource.swift" \
    "Sources/StowerMacUI/Board/StowerMessagesComposition.swift" \
    "Sources/StowerMacUI/Board/StowerMessagesMapping.swift" \
    | LC_ALL=C sort)"
SM_IMPORTERS="$(grep -RIlE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+StowerMessages([[:space:]]|$)' Sources/StowerMacUI/ 2>/dev/null | LC_ALL=C sort || true)"
if [ "$SM_IMPORTERS" != "$SM_ALLOWED" ]; then
    echo "ERROR: only the four engine-coupled StowerMacUI files may import StowerMessages:" >&2
    echo "$SM_ALLOWED" | sed 's/^/       allowed: /' >&2
    echo "       Found:" >&2
    echo "${SM_IMPORTERS:-<none>}" | sed 's/^/       /' >&2
    exit 1
fi

# 6c — This slice has no StowerCore boundary file in StowerMacUI yet (a future
#      search/index slice adds one and relaxes this — do NOT permanently ban StowerCore).
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+StowerCore([[:space:]]|$)' Sources/StowerMacUI/ 2>/dev/null; then
    echo "ERROR: StowerMacUI imports no StowerCore in this slice (add a boundary file when a search slice needs it)" >&2
    exit 1
fi

# 6d — The app/UI slice never probes the filesystem or DB itself; the engine reads
#      chat.db behind its facade. Bans direct FileManager/reachability/Data/TCC/sqlite/GRDB.
if grep -RInE --include="*.swift" -i 'FileManager\.default|checkResourceIsReachable|contentsOfDirectory|isReadableFile|Data\(contentsOf:|(^|[^a-z])tcc([^a-z]|$)|sqlite|grdb' StowerMac/StowerMac Sources/StowerMacUI 2>/dev/null; then
    echo "ERROR: the StowerMac app/UI slice must not touch the filesystem or DB directly (the engine does)" >&2
    exit 1
fi

# 6e — chat.db must not be a literal in production app/UI code: the FDA disclosure
#      renders the path from the .fullDiskAccessMissing(path:) payload, never a constant.
if grep -RInE --include="*.swift" 'chat\.db' StowerMac/StowerMac Sources/StowerMacUI 2>/dev/null; then
    echo "ERROR: chat.db must not appear as a literal in app/UI code — render it from the FDA payload" >&2
    exit 1
fi

# 6f — The Xcode app entry imports ONLY SwiftUI + StowerMacUI — never the engine/db.
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(GRDB|FoundationModels|Photos|PhotoKit|StowerMessages|StowerCore)([[:space:]]|$)' StowerMac/StowerMac 2>/dev/null; then
    echo "ERROR: the StowerMac app entry must import only SwiftUI + StowerMacUI, never the engine/db" >&2
    exit 1
fi

# 6g — No logging in StowerMacUI. The license key and the activate response (which
#      carries customer PII) flow through this module; a stray print/Logger/os_log/
#      NSLog would leak them. Locks the key-never-logged invariant (authored via
#      /harden-guardrail). Anchored to real call sites so words like "footprint" or
#      "Logger" in a comment can't trip it; green today.
if grep -RInE --include="*.swift" '(^|[^A-Za-z0-9_])(print|NSLog|os_log)[[:space:]]*\(|(^|[^A-Za-z0-9_])Logger[[:space:]]*\(' Sources/StowerMacUI 2>/dev/null; then
    echo "ERROR: no logging in Sources/StowerMacUI — the license key / activate-response PII must never reach logs (remove the print/Logger/os_log/NSLog call)" >&2
    exit 1
fi

# 6h — The DEBUG launch-arg seam is NEVER compiled into a Release archive: the
#      StowerLicenseDebugArguments type is DECLARED inside #if DEBUG, and
#      StowerLicenseGate REFERENCES it only inside #if DEBUG. A Release reference to
#      this #if DEBUG-only lease-wipe / fingerprint-pin lever would ship it to
#      customers (I-H5). Region-aware: a line-oriented grep cannot express "outside a
#      #if DEBUG region", so awk tracks #if DEBUG/#else/#endif nesting. The
#      `swift build -c release` in CI is the authoritative gate (an out-of-#if-DEBUG
#      reference is a hard compile error); this is the fast local canary.
debug_region_violation() {
    # $1 = file, $2 = ERE pattern. Exits non-zero (printing FILE:LINE) when a line
    # matching $2 appears OUTSIDE every enclosing release-excluding #if DEBUG region.
    # Pure-comment lines (// …) are ignored — a doc mention is not a compile reference.
    awk -v pat="$2" '
        /^[[:space:]]*#if[[:space:]]+DEBUG([[:space:]]|$)/ { depth++; dbg[depth]=1; act[depth]=1; excl++; next }
        /^[[:space:]]*#if([[:space:]]|$)/                  { depth++; dbg[depth]=0; act[depth]=0; next }
        /^[[:space:]]*#(else|elseif)([[:space:]]|$)/       { if (depth>0 && dbg[depth] && act[depth]) { excl--; act[depth]=0 } next }
        /^[[:space:]]*#endif([[:space:]]|$)/               { if (depth>0) { if (dbg[depth] && act[depth]) excl--; depth-- } next }
        /^[[:space:]]*\/\//                                { next }
        ($0 ~ pat && excl==0)                              { print FILENAME ":" NR; bad=1 }
        END { exit (bad ? 1 : 0) }
    ' "$1"
}
if ! debug_region_violation \
    Sources/StowerMacUI/Startup/StowerLicenseDebugArguments.swift \
    'struct[[:space:]]+StowerLicenseDebugArguments' \
    || ! debug_region_violation \
    Sources/StowerMacUI/Startup/StowerLicenseGate.swift \
    'StowerLicenseDebugArguments'; then
    echo "ERROR: the StowerLicenseDebugArguments seam must be #if DEBUG-only — its type must be declared inside #if DEBUG and referenced (in StowerLicenseGate) only inside #if DEBUG, or a lease-wipe/fingerprint-pin lever ships to customers (I-H5)" >&2
    exit 1
fi

# 6i — The /health non-default-trial-duration canary is actually WIRED, not just
#      the helper unit-tested: index.ts's /health handler must call
#      trialDurationHealthFields( so a TRIAL_DURATION_SECONDS leak onto prod is loud
#      (I-H10). Must-be-PRESENT polarity: a no-match fails. The `(` excludes the bare
#      import (which has no paren), so only the real call site satisfies it.
if ! grep -qE 'trialDurationHealthFields\(' supabase/functions/license/index.ts 2>/dev/null; then
    echo "ERROR: index.ts's /health handler must call trialDurationHealthFields( — the non-default trial-duration canary is unwired (I-H10)" >&2
    exit 1
fi

# 6j — DEBUG is NEVER defined in a Release build configuration of StowerMac.xcodeproj:
#      a DEBUG in the Xcode Release config would compile every #if DEBUG lever
#      (lease-wipe, fingerprint pin) INTO the shipped archive — and neither the SPM
#      `swift build -c release` (different build system) nor the 6h source guard would
#      catch it (I-H11). Block-scoped: walk each XCBuildConfiguration, remember its
#      SWIFT_ACTIVE_COMPILATION_CONDITIONS, fail if a `name = Release;` block carries
#      DEBUG. Dependency-free awk (no plutil/jq/python).
if ! awk '
        /isa = XCBuildConfiguration;/         { hasDebug=0; next }
        /SWIFT_ACTIVE_COMPILATION_CONDITIONS/ { if ($0 ~ /DEBUG/) hasDebug=1; next }
        /name = Release;/                     { if (hasDebug) { print "Release config defines DEBUG at line " NR; bad=1 } hasDebug=0; next }
        /name = Debug;/                       { hasDebug=0; next }
        END { exit (bad ? 1 : 0) }
    ' StowerMac/StowerMac.xcodeproj/project.pbxproj; then
    echo "ERROR: a Release build configuration of StowerMac.xcodeproj defines DEBUG — every #if DEBUG lever would ship in the archive; remove DEBUG from the Release config's SWIFT_ACTIVE_COMPILATION_CONDITIONS (I-H11)" >&2
    exit 1
fi
