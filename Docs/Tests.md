# Tests — conventions & naming standard

The one place that defines how tests are written in this repo, so every author
(human or AI) produces the same shape and we stop accumulating naming variants.
Mechanics (framework, file layout) are enforced by `AGENTS.md` + `Scripts/precheck.sh`;
this file owns the **naming standard** and its rationale.

## Framework & layout (already gated)

- **Swift Testing only** — `@Test` / `@Suite` / `#expect` / `#require`. No `XCTest` in
  new tests (`AGENTS.md`).
- **One file per type under test**, in `Tests/<ModuleName>Tests/` (`AGENTS.md`).
- No `try!` / force-unwrap; use `try` / `#require` (`AGENTS.md`, `swift-signal-review`).

## Naming standard (the rule)

**Every `@Test` carries a string display name: a lowercase, present-tense sentence
describing the *behavior*.** A `@Suite`'s display name, when present, is a short
**label** for the type/subsystem under test — a noun phrase like
`"StowerDiagnosticsConsent"`, not a behavior sentence. The Swift function/struct name
is a short identifier only — never the behavior description.

```swift
// ✅ standard
@Test("a stale load's late result is discarded, not applied (I13)")
func staleLoadDiscarded() { ... }

@Test("undecodable storage defaults diagnostics on")
func undecodableStorageDefaultsOn() { ... }

@Suite("StowerDebtBoardProvider") struct StowerDebtBoardProviderTests { ... }
```

```swift
// ❌ do not: a behavioral assertion crammed into a bare camelCase name,
//    no display string. Unreadable in source and in test output.
@Test func analyticsStorageKeyNeverCollidesWithShownFlag() { ... }

// ❌ do not: XCTest-style `test` prefix.
@Test func testFreshInstallDefaultsOn() { ... }
```

Rules, precisely:

1. **The `@Test("…")` display string is mandatory** and holds the behavior as a
   natural sentence.
2. **The `func` name is a short label, not the description.** camelCase is fine
   *for the identifier* — what's banned is using camelCase *as* the behavioral
   description with no display string. (A short label like `foodTruckExists` is fine;
   a run-on like `givenEmptyInventoryTruckReturnsNilNotError` is not.)
3. **No `test` prefix** (Swift Testing discovers via the `@Test` macro, not a name
   convention — the prefix is dead XCTest habit).
4. **Tag the invariant when the test guards one:** append `(I13)` / `(I5)` etc. so a
   failing test in CI output points straight at the documented invariant it protects.
5. **Length: no cap.** The constraint is **one behavior per test**, not a character
   count — Apple's docs and community guidance specify no maximum. If a name needs an
   "and" to describe two behaviors, **split the test**; do not shorten the name.

## Why strings, not camelCase (rationale — so the rule sticks)

- A Swift **function name is an identifier**: no spaces, no punctuation. A behavioral
  description *is* a sentence. `@Test("…")` stops those two needs from fighting — the
  compiler gets an identifier, the reader gets a sentence.
- Swift Testing **discovers tests via the `@Test` macro, not a name prefix** (unlike
  XCTest's `testXxx`), so the function name no longer has to double as the description
  — the string carries it.
- The display name is **what you read in Xcode's navigator, `swift test` output, and
  CI failure logs**. `✗ "a stale load's late result is discarded (I13)"` tells you
  what broke; `✗ staleLoadDiscarded` makes you go read the code.

## Raw identifiers (deferred until Swift 6.2+)

Swift 6.2 adds backtick **raw identifiers**, which let the function name itself be a
sentence and remove the string/label duplication:

```swift
@Test func `a stale load's late result is discarded (I13)`() { ... }
```

This is a valid future evolution, but **do not use it yet**: adopting it now would
create a *third* naming variant alongside the string-display form. Until the toolchain
is confirmed on Swift 6.2+ and we decide to migrate, the `@Test("…")` string form is
the single standard.

## Current state & the unification debt

Most of the suite (~85%, e.g. the board / startup / messages-access / config tests)
already follows this standard. The **analytics / diagnostics / crash-reporting** suites are a
holdover of bare camelCase behavioral names (e.g. `analyticsStorageKeyNeverCollidesWithShownFlag`).
Migrating those to `@Test("…")` is tracked as a **separate, deferred** task — it is
**not** bundled into unrelated feature work. New tests in those files still follow the
standard above; do not add new camelCase-only behavioral names.
