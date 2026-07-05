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
- Do not name a test with a bare camelCase behavioral name or a `test` prefix. Every
  `@Test`/`@Suite` carries a `("…")` display string describing ONE behavior as a
  present-tense sentence (tag the invariant it guards, e.g. `(I5)`); the `func` name is
  a short label, not the description. Full standard + rationale: `Docs/Tests.md`.
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

## Static source guards (`precheck.sh` `6x` family)

Some invariants are enforced by asserting a textual/structural fact about the
source tree at gate time — *"X is/isn't present, here"* — rather than by a unit
test. They live as numbered `# 6x — WHAT, WHY` blocks in `Scripts/precheck.sh`,
each a single check that does `echo "ERROR: <what + how to fix>" >&2; exit 1` on
violation, anchored to real call sites (so a stray word in a comment can't trip
it).

Add a new one as the **next member of this family — never a parallel mechanism.**
Pick the tool by the assertion's shape:

- **grep** (`grep -RInE`) when the fact is **line-local** — a token's
  presence/absence anywhere in the paths.
- **awk** when the fact depends on **region or block structure** — "only inside a
  `#if DEBUG` region," "only inside a named pbxproj `XCBuildConfiguration` block."
  grep is line-oriented and cannot track which region a line is in.

**Polarity** is just which outcome trips `exit 1`: must-be-**absent** → a *match*
fails (the default); must-be-**present** → a *no-match* fails
(`grep -q … || { echo "ERROR: …" >&2; exit 1; }`).

No external deps (no plutil/jq/python) — these run on every commit.

## Out of scope for v1

- Do not write any reply-**sending** code: no AppleScript `send`, no IMCore, no
  synthetic Return/Enter, no programmatic message transmission of any kind.
  **Populating** the Messages compose field for the user to send manually IS
  allowed (the drafts feature copies the draft to the clipboard, opens the
  conversation, and posts a synthetic ⌘V — never a Return). v1 stays send-free.
- Do not pull in Hummingbird, swift-nio, or any HTTP server dependency.
  v2 territory.
- Do not read or write face-identity tables in `Photos.sqlite` (ZPERSON,
  ZDETECTEDFACE). If photo indexing is ever built (see "Photos — two different
  features" below), it uses PhotoKit + FastVLM captions, never those tables.

## Photos — two different features, do not conflate them

"Photos" means two unrelated things in Stower. Keep them separate in scope and in
code:

- **Photo *indexing / recall*** — the `StowerPhotos` adapter reading the user's photo
  library via PhotoKit and captioning it with FastVLM so photos become a searchable
  source (today `Sources/StowerPhotos` is only a scaffold). This is **uncertain and
  currently unlikely** — it hinges on unresolved technical details *and* product
  direction, and may never ship. Do not build toward it or assume it lands; leave
  `StowerPhotos` a scaffold until a discussion + brief + plan says otherwise.
- **Photo *attachment in a draft*** — letting the user **drag-and-drop a photo onto a
  draft** so it rides along into the Messages compose field. This is **in scope, cheap
  enough for v0**, and serves the core JTBD ("help me send a text" — real texts often
  include a photo). It needs **no** PhotoKit, no `StowerPhotos`, no library indexing:
  the photo is user-picked and delivered by the **same clipboard + synthetic ⌘V path**
  (`StowerMessagesDropper`) as a text draft — never a Return, so it stays send-free
  (see "Out of scope for v1"). Staging an attachment onto the pasteboard is
  *populating* the compose field, not sending — it sits inside that send-free
  carve-out. The one open build-to-learn detail: getting text **and** image into the
  field in one shot (multi-item pasteboard vs. a two-step paste) — verify empirically,
  don't assume.

## Conventions

- All public top-level declarations in a `Stower*` module must begin with
  `Stower`, or be nested inside a type that does. Underscore-prefixed names
  are treated as internal API even if `public`.
- Tests go in `Tests/<ModuleName>Tests/`. One file per type under test.
- Subsystem rationale lives in `Docs/<Subsystem>.md`. Update it when the
  rationale changes — not when the code changes.
- After each meaningful commit, update `PLAN.md`'s "Status" section so the
  next session can re-enter without re-reading the diff.
- When writing or editing a plan/spec/doc, refer to real codebase symbols
  (types, functions, views, state cases) by their **exact names** — e.g.
  `StowerModelUnavailableView`, not "the model screen". Invented English
  paraphrases drift out of sync and aren't greppable; exact names are. If the
  symbol doesn't exist yet, name the one you intend to create, not a vibe.
- **Naming map: product identity vs. internal structure — do not conflate them.**
  Two distinctions, both locked by `Scripts/precheck.sh`'s `6p` guard:
  1. **Product identity ≠ internal `StowerMac` structure.** The user-facing product
     name (`Stower`/`Stower Test`, the pbxproj's `PRODUCT_NAME` /
     `PRODUCT_BUNDLE_IDENTIFIER` / `INFOPLIST_KEY_CFBundleDisplayName`) is
     independent of the internal
     `StowerMac` scheme, `StowerMac.xcodeproj`, and the `StowerMacUI` /
     `StowerCore` / `StowerMessages` / `StowerPhotos` SPM module names. Do
     **not** sweep `StowerMac → Stower` anywhere in scheme/project/module
     names — it breaks `-scheme StowerMac` in `ci.yml` + `release.yml`, every
     `import StowerMacUI`, and `precheck.sh`'s own path guards.
  2. **Within product identity, `PRODUCT_NAME` and the display name are
     deliberately different values — do not unify them.** `PRODUCT_NAME` stays
     space-free (`StowerTest` / `Stower`) because it drives the `.app` filename,
     the `Contents/MacOS/` binary name (`EXECUTABLE_NAME`), the run scripts'
     derivation (`Scripts/run-app.sh` / `run-app-demo.sh`), and the `6p` guard's
     `PRODUCT_NAME` match. `INFOPLIST_KEY_CFBundleDisplayName` carries the space
     (`"Stower Test"`) for the menu-bar/Finder label only. Unifying them would
     break the `awk -F ' = '` derivation and the guard.

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
