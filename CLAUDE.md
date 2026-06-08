# Stower — Agent Conventions

You are working in a Swift monorepo for an always-local AI recall app.
Apply the following constraints to every change you make.

## Architecture rules

- Do not import `StowerPhotos` or `StowerMessages` from `StowerCore`.
  Dependency arrows point INTO StowerCore, never out of it.
- Do not import `StowerMessages` from `StowerPhotos`, or `StowerPhotos` from
  `StowerMessages`. The adapters never know about each other.
- Do not introduce a fourth source adapter in `Sources/`. New data sources go
  through a discussion + brief + plan before any module is created.
- Do not add a generic `Utilities` or `Common` module. Shared code goes in
  `StowerCore`.
- Do not bypass `StowerCore`'s `IndexedItem` protocol when adding records to
  the search index. Adapters produce IndexedItems; the index never imports
  PhotoKit or `chat.db`-specific GRDB types.

## Swift style

- Do not use `try!` or force-unwrap (`!`). Use `guard let` or `try` with
  explicit error handling.
- Do not omit doc comments on `public` declarations. Triple-slash only;
  no `/** */` blocks.
- Do not use `XCTest` for new tests. Use Swift Testing (`@Test`, `#expect`).
- Do not exceed function body length 40 lines or cyclomatic complexity 8
  without a `// swiftlint:disable:next` comment that explains why.
- Do not use real Photos or Messages data in test fixtures, prompts, debug
  logs, or network calls.

## Process

- Do not refactor unrelated code while implementing a feature. One commit,
  one concern.
- Do not skip `Scripts/precheck.sh`. If it fails, fix the cause, do not
  comment out the rule.
- Do not bypass `git commit` hooks with `--no-verify`.
- Do not modify `Package.resolved` directly. Run `swift package update`.

## Out of scope for v1

- Do not write any reply-sending code (AppleScript, IMCore, anything).
  v1 is recall-only.
- Do not pull in Hummingbird, swift-nio, or any HTTP server dependency.
  v2 territory.
- Do not read or write face-identity tables in `Photos.sqlite` (ZPERSON,
  ZDETECTEDFACE). Use PhotoKit + FastVLM captions.

## Conventions

- All public top-level declarations in a `Stower*` module must begin with
  `Stower`, or be nested inside a type that does. Underscore-prefixed names
  are treated as internal API even if `public`.
- Tests go in `Tests/<ModuleName>Tests/`. One file per type under test.
- Subsystem rationale lives in `Docs/<Subsystem>.md`. Update it when the
  rationale changes — not when the code changes.
- After each meaningful commit, update `PLAN.md`'s "Status" section so the
  next session can re-enter without re-reading the diff.
