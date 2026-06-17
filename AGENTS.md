# Stower — Agent Conventions

Canonical rule set for every AI coding agent in this repo (Claude Code, Codex,
and any other). `CLAUDE.md` imports this file with `@AGENTS.md`; do not duplicate
rules there.

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
- Do not use magic numbers/literals or global/file-scope constants. Define a
  constant as a named `static let` on the type it naturally belongs to, scoped
  to the narrowest access (`private` → `internal` → `public`) and co-located with
  its use (e.g. `StowerConversationStateExtractor.reciprocityWindowDays`,
  `StowerCoreMLEmbedder.maxBatch`). Use `Duration` for time intervals. Only
  introduce a case-less `enum` namespace for a *bag of homeless* constants with no
  natural home type — never a `Constants.swift` dumping ground.

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

## Signal-coding skills

These keep bad patterns from spreading. The skills live in `.claude/skills/`
(Claude Code's discovery path) and are mirrored to `.agents/skills/` via symlink so
Codex discovers them too. Any agent that does not auto-load skills should read and
follow the relevant `SKILL.md` directly. The bad→good pattern catalog is
`.claude/skills/SWIFT_PATTERNS.md` (single source of truth; read it before
reviewing or fixing Swift).

Run the full pattern pass once per branch, when you are about to open a PR — not on
every commit. Sweeping and hardening prompt the human, so running them mid-branch is
noise; batch them at PR time. (The mechanical gate, `precheck.sh`, still runs on every
commit.) Order matters — noticing comes before fixing:

1. Run `swift-signal-review` on the whole branch diff (`git diff origin/main...`) to
   notice the bad patterns in the changes you made.
2. For each noticed pattern the catalog marks `Sweep-able: yes`, run
   `swift-pattern-sweep` once to remove every instance repo-wide. Patterns marked
   `Sweep-able: no` (judgment/process/architectural) are fixed by hand, not swept.
3. For each pattern that also appears elsewhere in the codebase (recurs ≥2×), run
   `harden-guardrail`; it proposes test/CI enforcement and asks you how to lock the
   pattern down so it can't come back.

Do not add a new convention rule by hand — route it through `harden-guardrail` so it
lands as a gate first, an `AGENTS.md` rule only when it can't be mechanized, and gets
recorded in the catalog.
