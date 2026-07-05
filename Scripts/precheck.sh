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
#      CrashReporting/ is excluded: the scrubber legitimately pattern-matches the
#      token as a hard-stop fragment to detect accidental crash-payload leaks.
if grep -RInE --include="*.swift" 'chat\.db' StowerMac/StowerMac 2>/dev/null; then
    echo "ERROR: chat.db must not appear as a literal in StowerMacApp code — render it from the FDA payload" >&2
    exit 1
fi
if grep -RInE --include="*.swift" 'chat\.db' Sources/StowerMacUI \
    --exclude-dir=CrashReporting 2>/dev/null; then
    echo "ERROR: chat.db must not appear as a literal in UI code — render it from the FDA payload" >&2
    exit 1
fi

# 6f — The Xcode app entry imports ONLY SwiftUI + StowerMacUI + Sparkle — never the engine/db.
#      Sparkle is a first-party app-target dependency (Xcode project only, not Package.swift);
#      it is intentionally permitted here and in the Sparkle guard below.
if grep -RInE --include="*.swift" '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(GRDB|FoundationModels|Photos|PhotoKit|StowerMessages|StowerCore)([[:space:]]|$)' StowerMac/StowerMac 2>/dev/null; then
    echo "ERROR: the StowerMac app entry must import only SwiftUI + StowerMacUI + Sparkle, never the engine/db" >&2
    exit 1
fi

# 6g — Sparkle must NOT appear in the ROOT SPM graph (Package.swift or the root
#      Package.resolved). It lives in the Xcode project only (StowerMac.xcodeproj).
#      The Xcode project's own Package.resolved at
#      StowerMac/StowerMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
#      legitimately contains Sparkle; this guard targets only the root files.
if grep -iE 'sparkle' Package.swift Package.resolved 2>/dev/null; then
    echo "ERROR: Sparkle must not appear in the root SPM graph (Package.swift / Package.resolved)." >&2
    echo "       Sparkle is an Xcode-project-only dependency — never add it to Package.swift." >&2
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

# debug_region_violation — shared helper (used by 6m below). $1 = file,
# $2 = ERE pattern. Exits non-zero (printing FILE:LINE) when a line matching
# $2 appears OUTSIDE every enclosing release-excluding #if DEBUG region.
# Region-aware: a line-oriented grep cannot express "outside a #if DEBUG
# region", so awk tracks #if DEBUG/#else/#endif nesting. Pure-comment lines
# (// …) are ignored — a doc mention is not a compile reference.
debug_region_violation() {
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

# 6j — DEBUG is NEVER defined in a Release build configuration of StowerMac.xcodeproj:
#      a DEBUG in the Xcode Release config would compile every #if DEBUG lever
#      (the --clear-license / --reset-trial debug launch-arg seam) INTO the
#      shipped archive — and the SPM `swift build -c release` (a different
#      build system) would not catch it (I-H11). Block-scoped: walk each
#      XCBuildConfiguration, remember its
#      SWIFT_ACTIVE_COMPILATION_CONDITIONS, fail if a `name = Release;` block carries
#      DEBUG. Dependency-free awk (no plutil/jq/python). SWIFT_ACTIVE_COMPILATION_
#      CONDITIONS can be a parenthesized multiline list, so the value's DEBUG may sit
#      on a continuation line, not the assignment line — track the whole value region
#      (from the setting until its terminating `;`) so a multiline DEBUG isn't missed.
if ! awk '
        /isa = XCBuildConfiguration;/         { hasDebug=0; inSwiftCond=0; next }
        inSwiftCond                           { if ($0 ~ /DEBUG/) hasDebug=1; if ($0 ~ /;/) inSwiftCond=0; next }
        /SWIFT_ACTIVE_COMPILATION_CONDITIONS/ { if ($0 ~ /DEBUG/) hasDebug=1; if ($0 !~ /;/) inSwiftCond=1; next }
        /name = Release;/                     { if (hasDebug) { print "Release config defines DEBUG at line " NR; bad=1 } hasDebug=0; next }
        /name = Debug;/                       { hasDebug=0; next }
        END { exit (bad ? 1 : 0) }
    ' StowerMac/StowerMac.xcodeproj/project.pbxproj; then
    echo "ERROR: a Release build configuration of StowerMac.xcodeproj defines DEBUG — every #if DEBUG lever would ship in the archive; remove DEBUG from the Release config's SWIFT_ACTIVE_COMPILATION_CONDITIONS (I-H11)" >&2
    exit 1
fi

# 6k — TelemetryDeck is imported by EXACTLY ONE file: StowerTelemetryDeckReporter.swift.
#      Admits attributed imports with or without argument lists
#      (@preconcurrency, @testable, @attr(args)) by extending the attribute
#      sub-pattern to allow an optional parenthesised arg list. A second import
#      anywhere defeats the kill-switch quarantine. Must-be-EXACTLY-ONE polarity.
TD_ALLOWED="$(printf '%s\n' \
    "Sources/StowerMacUI/Analytics/StowerTelemetryDeckReporter.swift" \
    | LC_ALL=C sort)"
TD_IMPORTERS="$(grep -RIlE --include="*.swift" \
    '^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?([[:space:]]|$))*import[[:space:]]+([a-z]+[[:space:]]+)?TelemetryDeck([[:space:].]|$)' \
    Sources/ StowerMac/StowerMac/ 2>/dev/null | LC_ALL=C sort || true)"
if [ "$TD_IMPORTERS" != "$TD_ALLOWED" ]; then
    echo "ERROR: TelemetryDeck must be imported by exactly one file (StowerTelemetryDeckReporter.swift)." >&2
    echo "       Allowed: $TD_ALLOWED" >&2
    echo "       Found: ${TD_IMPORTERS:-<none>}" >&2
    exit 1
fi

# 6l — Sentry is imported by EXACTLY FOUR files: the two CrashReporting
#      production sources and their two direct test files. Admits attributed
#      imports with or without argument lists (@preconcurrency, @testable,
#      @attr(args)) — same pattern as 6k. A fifth Sentry import anywhere spreads
#      the vendor past the quarantine and defeats the kill-switch isolation.
#      Must-be-EXACTLY-FOUR polarity (sorted-set allowlist, same shape as 6b).
SENTRY_ALLOWED="$(printf '%s\n' \
    "Sources/StowerMacUI/CrashReporting/StowerCrashReporting.swift" \
    "Sources/StowerMacUI/CrashReporting/StowerSentryScrubber.swift" \
    "Tests/StowerMacUITests/StowerCrashReportingTests.swift" \
    "Tests/StowerMacUITests/StowerSentryScrubberTests.swift" \
    | LC_ALL=C sort)"
SENTRY_IMPORTERS="$(grep -RIlE --include="*.swift" \
    '^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?([[:space:]]|$))*import[[:space:]]+([a-z]+[[:space:]]+)?Sentry([[:space:].]|$)' \
    Sources/ StowerMac/StowerMac/ Tests/ 2>/dev/null | LC_ALL=C sort || true)"
if [ "$SENTRY_IMPORTERS" != "$SENTRY_ALLOWED" ]; then
    echo "ERROR: Sentry must be imported by exactly the two CrashReporting files + their two test files." >&2
    echo "       Allowed:" >&2
    echo "$SENTRY_ALLOWED" | sed 's/^/       /' >&2
    echo "       Found: ${SENTRY_IMPORTERS:-<none>}" >&2
    exit 1
fi

# 6m — options.debug must ONLY appear inside a #if DEBUG region in
#      StowerCrashReporting.swift. An unguarded options.debug in a Release archive
#      ships debug logging. Reuses the shared debug_region_violation awk helper.
if ! debug_region_violation \
    Sources/StowerMacUI/CrashReporting/StowerCrashReporting.swift \
    'options[[:space:]]*\.[[:space:]]*debug'; then
    echo "ERROR: options.debug must only appear inside a #if DEBUG region in" >&2
    echo "       StowerCrashReporting.swift — a Release-reachable assignment ships debug logging (6m)" >&2
    exit 1
fi

# 6n — No string interpolation (\() inside crash-reason trap messages or
#      queue/thread labels in first-party source. The KSCrash notable-address
#      converter promotes trap message content INTO exception.value (A5, spike).
#      First-party code must never inject user data into these strings; the
#      scrubber covers dependency-originated content. Pattern: \( inside a
#      fatalError/preconditionFailure/assertionFailure/precondition/assert message
#      argument, or inside a DispatchQueue(label:)/Thread.name assignment, in
#      Sources/ only. Grep family — line-local fact.
if grep -RInE --include="*.swift" \
    '(fatalError|preconditionFailure|assertionFailure|precondition|assert)[[:space:]]*\([^)]*\\\(' \
    Sources/ 2>/dev/null; then
    echo "ERROR: no string interpolation (\() in fatalError/preconditionFailure/" >&2
    echo "       assertionFailure/precondition/assert messages in Sources/ — user" >&2
    echo "       data interpolated here can leak into exception.value (A5). Use" >&2
    echo "       a static string; the scrubber covers introspected content (6n)." >&2
    exit 1
fi
if grep -RInE --include="*.swift" \
    'DispatchQueue[[:space:]]*\([[:space:]]*label:[[:space:]]*"[^"]*\\\(' \
    Sources/ 2>/dev/null; then
    echo "ERROR: no string interpolation (\() in DispatchQueue(label:) strings in" >&2
    echo "       Sources/ — user data in queue labels can reach crash-reason strings (6n)." >&2
    exit 1
fi
# Thread.name interpolation (the comment above claims this coverage). Scoped to
# `Thread.name` / `Thread.current.name` so it can't false-positive on an unrelated
# `.name` property; thread names surface in crash reports, so user data in them
# would reach crash-reason strings (6n).
if grep -RInE --include="*.swift" \
    'Thread[[:space:]]*\.[[:space:]]*(current[[:space:]]*\.[[:space:]]*)?name[[:space:]]*=[[:space:]]*"[^"]*\\\(' \
    Sources/ 2>/dev/null; then
    echo "ERROR: no string interpolation (\() in Thread.name assignments in" >&2
    echo "       Sources/ — user data in thread names can reach crash-reason strings (6n)." >&2
    exit 1
fi

# 6o — I5: the app's only license-path network egress is api.lemonsqueezy.com;
#      no residual Keygen/edge-function/Supabase host or path may sneak back in
#      (the whole backend — supabase/, Scripts/Keygen/ — is deleted by design,
#      not dormant). Two polarities in one guard:
#        must-be-ABSENT: a Keygen/edge-function/Supabase token anywhere in
#        Sources/ (a match fails).
#        must-be-PRESENT: api.lemonsqueezy.com must still appear somewhere in
#        Sources/ (a no-match fails) — proves the guard itself hasn't silently
#        stopped covering the real client file.
if grep -RInE --include="*.swift" -i \
    'supabase|keygen|/check-in|mint-trial|mint_trial' \
    Sources/ 2>/dev/null; then
    echo "ERROR: a residual Keygen/edge-function/Supabase reference was found in Sources/ —" >&2
    echo "       the entire backend was deleted (JC4); no dormant reference may remain (I5)." >&2
    exit 1
fi
if ! grep -RIlE --include="*.swift" -q 'api\.lemonsqueezy\.com' Sources/ 2>/dev/null; then
    echo "ERROR: api.lemonsqueezy.com must appear in Sources/ — it is the app's only" >&2
    echo "       license-path network egress (I5); this guard would otherwise pass" >&2
    echo "       vacuously if the activate client's host literal ever moved/vanished." >&2
    exit 1
fi

# 6p — Locks the product-vs-internal naming split (INV1-INV4, dev/prod TCC isolation):
#      the pbxproj's Debug/Release identity (bundle id, PRODUCT_NAME, display name)
#      must stay exactly as decided, and the internal StowerMac scheme/target must
#      never be swept away by a "consistency" rename. Two independently-checked facts.
#
#      Fact 1 — pbxproj identity split. The pbxproj has TWO Debug + TWO Release
#      XCBuildConfiguration blocks: a project-level pair (no PRODUCT_NAME/bundle-id/
#      display-name at all) and a target-level pair (carries all three). A guard
#      that requires "every Debug block has PRODUCT_NAME=StowerTest" false-positives
#      on the empty project-level block and blocks every commit — so this uses
#      EXISTENCE semantics: classify a config as an "identity config" iff it carries
#      a PRODUCT_NAME line, then require exactly ONE identity Debug config and
#      exactly ONE identity Release config, each fully correct. The display name is
#      matched as the FULL quoted literal ("Stower Test") — never via a $-positional
#      field split, which would truncate at the space.
if ! awk '
        /isa = XCBuildConfiguration;/ { has_pn=0; pn_ok=0; bundle_ok=0; display_ok=0; next }
        /^\t+PRODUCT_NAME = / {
            has_pn=1
            if ($0 ~ /^\t+PRODUCT_NAME = StowerTest;/) pn_ok="debug"
            else if ($0 ~ /^\t+PRODUCT_NAME = Stower;/) pn_ok="release"
            next
        }
        /^\t+PRODUCT_BUNDLE_IDENTIFIER = / {
            if ($0 ~ /= emilykangdev\.Stower\.debug;/) bundle_ok="debug"
            else if ($0 ~ /= emilykangdev\.Stower;/) bundle_ok="release"
            next
        }
        /^\t+INFOPLIST_KEY_CFBundleDisplayName = / {
            if ($0 ~ /^\t+INFOPLIST_KEY_CFBundleDisplayName = "Stower Test";/) display_ok="debug"
            else if ($0 ~ /^\t+INFOPLIST_KEY_CFBundleDisplayName = Stower;/) display_ok="release"
            next
        }
        /name = Debug;/ {
            if (has_pn) {
                debug_ident++
                if (pn_ok=="debug" && bundle_ok=="debug" && display_ok=="debug") debug_good++
            }
            next
        }
        /name = Release;/ {
            if (has_pn) {
                rel_ident++
                if (pn_ok=="release" && bundle_ok=="release" && display_ok=="release") rel_good++
            }
            next
        }
        END { exit (debug_ident==1 && debug_good==1 && rel_ident==1 && rel_good==1) ? 0 : 1 }
    ' StowerMac/StowerMac.xcodeproj/project.pbxproj; then
    echo "ERROR: project.pbxproj Debug/Release identity config is wrong or missing —" >&2
    echo "       expected exactly one Debug identity config with PRODUCT_NAME=StowerTest," >&2
    echo "       PRODUCT_BUNDLE_IDENTIFIER=emilykangdev.Stower.debug, and" >&2
    echo "       INFOPLIST_KEY_CFBundleDisplayName=\"Stower Test\" (quoted); and exactly" >&2
    echo "       one Release identity config with PRODUCT_NAME=Stower," >&2
    echo "       PRODUCT_BUNDLE_IDENTIFIER=emilykangdev.Stower, and" >&2
    echo "       INFOPLIST_KEY_CFBundleDisplayName=Stower. If you INTENDED to change the" >&2
    echo "       product identity, update BOTH the pbxproj AND this guard's expected" >&2
    echo "       literals here (precheck.sh) — do NOT rename the internal StowerMac" >&2
    echo "       scheme/target/modules (see AGENTS.md naming-map). (6p)" >&2
    exit 1
fi

#      Fact 2 — internal scheme/target survives. A bare `grep -q -- -scheme StowerMac`
#      alone would pass on a stale comment, so this asserts THREE facts: the shared
#      scheme file exists, the PBXNativeTarget still carries `name = StowerMac;`, and
#      at least one ACTIVE (non-comment) workflow line still invokes `-scheme StowerMac`.
if [ ! -f "StowerMac/StowerMac.xcodeproj/xcshareddata/xcschemes/StowerMac.xcscheme" ]; then
    echo "ERROR: StowerMac.xcscheme is missing — the internal StowerMac scheme must never" >&2
    echo "       be renamed/removed as part of a product-identity change (see AGENTS.md" >&2
    echo "       naming-map). If this is an intentional internal rename, update this" >&2
    echo "       guard's expected path here (precheck.sh). (6p)" >&2
    exit 1
fi
if ! grep -RInE '^\t\t\tname = StowerMac;' StowerMac/StowerMac.xcodeproj/project.pbxproj 2>/dev/null | grep -q .; then
    echo "ERROR: PBXNativeTarget name = StowerMac; not found in project.pbxproj — the" >&2
    echo "       internal target name must never be swept to match the product identity" >&2
    echo "       (see AGENTS.md naming-map). If this is an intentional internal rename," >&2
    echo "       update this guard's expected name here (precheck.sh). (6p)" >&2
    exit 1
fi
if ! grep -RInE -- '-scheme StowerMac' .github/workflows/release.yml .github/workflows/ci.yml 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' | grep -q .; then
    echo "ERROR: no active (non-comment) '-scheme StowerMac' line found in" >&2
    echo "       .github/workflows/release.yml or ci.yml — the internal scheme name must" >&2
    echo "       never be swept to match the product identity (see AGENTS.md naming-map)." >&2
    echo "       If this is an intentional internal rename, update this guard's expected" >&2
    echo "       scheme name here (precheck.sh). (6p)" >&2
    exit 1
fi

# 6q — No Keychain-ITEM API in first-party Swift (Sources/ + StowerMac/StowerMac/).
#      The diagnostics install record lives in UserDefaults, not the Keychain: a
#      Keychain read on the launch path raised the macOS "allow access to your
#      keychain" dialog that BLOCKS the app from opening for cross-signature
#      upgraders. That read is removed; this guard keeps it from coming back.
#      SCOPE: keychain-item access only — SecItem*/SecKeychain* and the item-query
#      kSec* constants. Legit Security.framework use stays ALLOWED: `import Security`,
#      SecKey* (crypto), SecTrust* (TLS pinning), SecCertificate* (code-signing).
#      Tests/ is intentionally out of scope (test fixtures never ship). Grep family
#      — line-local token fact; no \b (BSD grep lacks it), explicit tokens instead.
#      Must-be-ABSENT polarity (a match fails).
if grep -RInE --include="*.swift" \
    'SecItem[A-Za-z]*|SecKeychain[A-Za-z]*|kSecClass|kSecMatchLimit|kSecReturnData|kSecReturnAttributes|kSecReturnRef|kSecValueData|kSecValueRef|kSecAttrService|kSecAttrAccount|kSecAttrGeneric|kSecAttrSynchronizable|kSecUseDataProtectionKeychain' \
    Sources/ StowerMac/StowerMac/ 2>/dev/null; then
    echo "ERROR: a Keychain-item API (SecItem*/SecKeychain*/item-query kSec* constant)" >&2
    echo "       was found in first-party Swift. The diagnostics record lives in" >&2
    echo "       UserDefaults precisely because a launch-path Keychain read raised a" >&2
    echo "       password dialog that blocks app launch — do not reintroduce it. Legit" >&2
    echo "       Security.framework use (import Security, SecKey/SecTrust/SecCertificate)" >&2
    echo "       is allowed; if you need one that trips this guard, narrow the token list" >&2
    echo "       here (precheck.sh). Keep any 'Keychain' rationale in prose, not API tokens. (6q)" >&2
    exit 1
fi
