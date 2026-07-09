# Swift pattern catalog — Stower

Single source of truth for "bad pattern → good pattern" in this repo. The three
signal-coding skills (`swift-signal-review`, `swift-pattern-sweep`,
`harden-guardrail`) all read this file. `AGENTS.md` points here. When a recurring
problem becomes a rule, it gets an entry here first.

Why this file exists: an AI propagates whatever it reads. One bad pattern, left in
the tree, becomes the template the next agent copies. The fix is not "review harder"
but "make the good pattern the only pattern the codebase shows, and the bad pattern
something an automated gate rejects." Each entry below names the bad form, why it
spreads, the one good form, and what already catches it (or that nothing does yet).

Legend for **Caught by**:
- `gate` — `Scripts/precheck.sh` already fails on this. Mechanical, non-negotiable.
- `judgment` — no automated check; relies on `swift-signal-review`. Candidate for
  `harden-guardrail` to mechanize.

Legend for **Sweep-able**:
- `yes` — one mechanical, repo-wide find-and-replace to the single good form is
  meaningful, so `swift-pattern-sweep` can eradicate every instance.
- `no` — the fix needs judgment, authored content, an architectural move, or is a
  process rule. There is no single mechanical replacement, so `swift-pattern-sweep`
  does not apply; route recurrences to `harden-guardrail` and fix sites by hand.

---

## 1. Force unwrap and force try

- **Bad:** `let x = dict["k"]!`, `try! decoder.decode(...)`, `value as! Foo`.
- **Why it spreads:** the shortest path to "it compiles." Each one is a latent crash;
  copied into a hot path it becomes a class of crashes.
- **Good:** `guard let x = dict["k"] else { ... }`, `try` with a typed error,
  `guard let foo = value as? Foo else { ... }`.
- **Caught by:** `gate` — swift-format `NeverForceUnwrap` / `NeverUseForceTry`,
  swiftlint `force_unwrapping` / `force_cast` / `force_try`.
- **Sweep-able:** no — there is no single good form; each site needs a decision
  (guard-return, throw, `as?` fallback), so a mechanical replace could change behavior.
  The `gate` already blocks new instances.

## 2. Deep nesting / high cyclomatic complexity

- **Bad:** stacked `if let` / `switch` / `for` pyramids; one function deciding many things.
- **Why it spreads:** AI adds "just one more branch" per prompt; complexity creeps
  past the point where the model can still reason about the function it wrote.
- **Good:** early-return `guard`; extract a named helper per concern; flatten with
  `map`/`compactMap`/`first(where:)`.
- **Caught by:** `gate` — swiftlint `cyclomatic_complexity` warning 8. If a function
  legitimately needs more, add `// swiftlint:disable:next` with a one-line reason.
- **Sweep-able:** no — each site needs a judgment-driven refactor, not one replacement.

## 3. Over-long functions

- **Bad:** a 60-line function body doing setup + work + formatting.
- **Why it spreads:** becomes the size template for the next function.
- **Good:** keep bodies under 40 lines; extract phases into named functions.
- **Caught by:** `gate` — swiftlint `function_body_length` warning 40.
- **Sweep-able:** no — extraction points differ per function.

## 4. Undocumented public API

- **Bad:** `public func search(...)` with no doc comment.
- **Why it spreads:** undocumented public surface is unstable surface; the next agent
  guesses intent and guesses wrong.
- **Good:** `///` one-line summary first, then params/returns. Triple-slash only.
- **Caught by:** `gate` — swift-format `AllPublicDeclarationsHaveDocumentation` +
  `BeginDocumentationCommentWithOneLineSummary`, swiftlint `missing_docs`.
- **Sweep-able:** no — the doc text must be authored per declaration.

## 5. Loose access control (public-by-default)

- **Bad:** marking new types/members `public` because the AI defaults to it.
- **Why it spreads:** every `public` is a promise; an accidental public surface gets
  depended on and can't be narrowed later.
- **Good:** strictest ACL that works. `internal` by default, `public` only when a
  cross-module consumer truly needs it. Prefer `private` to `fileprivate`.
- **Caught by:** `judgment`. swiftlint `explicit_acl` / `explicit_top_level_acl` gate
  that an ACL keyword is *present*, but they do not flag an over-broad one — an
  unnecessarily `public` declaration still passes the gate and needs review.
- **Sweep-able:** no — deciding which `public` should be `internal` depends on the
  cross-module consumers; that is judgment, not a mechanical replace.

## 6. Block comments

- **Bad:** `/** ... */` doc blocks.
- **Good:** `///` triple-slash.
- **Caught by:** `gate` — swift-format `NoBlockComments` / `UseTripleSlashForDocumentationComments`.
- **Sweep-able:** yes — convert `/** */` to `///` mechanically.

## 7. XCTest in new tests

- **Bad:** `import XCTest`, `class FooTests: XCTestCase`, `XCTAssertEqual`.
- **Why it spreads:** mixing two test frameworks splits the conventions; the next
  test copies whichever it saw last.
- **Good:** Swift Testing — `@Test`, `@Suite`, `#expect`, `#require`. For struct
  diffs use `expectNoDifference` (swift-custom-dump).
- **Caught by:** `judgment` (no gate yet). Detect: `import XCTest` under `Tests/`.
  Strong candidate for `harden-guardrail` to add a precheck grep.
- **Sweep-able:** no — each test's assertions and structure must be rewritten.

## 8. Module-boundary violation

- **Bad:** `import StowerPhotos`/`StowerMessages` inside `StowerCore`; adapters
  importing each other.
- **Why it spreads:** one back-arrow import collapses the whole dependency story; the
  layering stops being a constraint the AI can rely on.
- **Good:** dependency arrows point INTO `StowerCore`. Adapters never know about each
  other. Cross the boundary via the `StowerIndexedItem` protocol.
- **Caught by:** `gate` — `Scripts/precheck.sh` step 5.
- **Sweep-able:** no — fixing it means moving code across modules, not replacing text.

## 9. Bypassing IndexedItem

- **Bad:** adding records to the index with PhotoKit or chat.db/GRDB-specific types
  leaking into `StowerCore`.
- **Why it spreads:** the index gains a second ingestion path; new sources copy the
  leaky one instead of the protocol.
- **Good:** adapters produce values conforming to `StowerCore.StowerIndexedItem`; the
  index only ever sees `StowerIndexedItem`.
- **Caught by:** `judgment`.
- **Sweep-able:** no — an architectural change per ingestion path.

## 10. Public name without `Stower` prefix

- **Bad:** `public struct SearchResult` at top level in a `Stower*` module.
- **Why it spreads:** breaks the swift-nio-style namespace convention; collisions and
  ambiguity follow.
- **Good:** `public struct StowerSearchResult`, or nest the type inside a `Stower*`
  type. Underscore-prefixed public names read as internal.
- **Caught by:** `judgment`.
- **Sweep-able:** yes — rename the declaration and its references repo-wide.

## 11. Mixed structural + behavioral change in one commit

- **Bad:** a feature commit that also renames/moves/refactors unrelated code.
- **Why it spreads:** the diff becomes unreviewable, so it gets rubber-stamped, so the
  bad lines inside it ship. The blog's #1 lesson: a bad line of a plan becomes
  hundreds of bad lines of code.
- **Good:** one commit, one concern. Refactors ship separately from features.
- **Caught by:** `judgment`. Three things get a diff rejected on sight: an unexpected
  loop, functionality nobody asked for, a test weakened or deleted to make it pass.
- **Sweep-able:** no — this is a process rule about how changes are committed, not a
  code shape. Route recurrences to `harden-guardrail` / `AGENTS.md`.

## 12. Real Photos/Messages data in fixtures, logs, prompts

- **Bad:** committing real captions, real chat text, real attachments as test data;
  printing them in debug logs.
- **Why it spreads:** a privacy leak that becomes the fixture template.
- **Good:** synthetic fixtures only, generated in-test. Never real user data anywhere
  committed or logged.
- **Caught by:** `judgment`.
- **Sweep-able:** no — deciding what is real user data and replacing it with safe
  synthetic equivalents needs judgment, not a mechanical replace.

## 13. Catch-and-ignore

- **Bad:** `do { ... } catch { }` or `try?` that silently swallows a real failure.
- **Why it spreads:** the failure becomes invisible; the next agent assumes the call
  can't fail.
- **Good:** handle it, or propagate with `throws`. `try?` only when nil genuinely is
  the right, intended outcome (and say so).
- **Caught by:** `judgment`.
- **Sweep-able:** no — the right handling differs per call site.

## 14. New `Utilities`/`Common` module or a fourth source adapter

- **Bad:** creating a grab-bag module, or a fourth `Sources/` adapter, mid-feature.
- **Why it spreads:** the grab-bag attracts everything; the architecture stops being
  legible.
- **Good:** shared code goes in `StowerCore`. New data sources go through
  discussion + brief + plan before any module exists.
- **Caught by:** `judgment`.
- **Sweep-able:** no — an architecture/process decision, not a code shape.

## 15. Naming by type instead of role

- **Bad:** `let string = ...`, `let widgetFactory: Supplier`.
- **Why it spreads:** every reader re-derives intent; clarity at the point of use rots.
- **Good:** name by role — `greeting`, `supplier`. Booleans read as assertions
  (`isEmpty`, `intersects`). Mutating/non-mutating pairs follow `-ed`/`-ing`.
  Anchor to Apple's API Design Guidelines.
- **Caught by:** `judgment`.
- **Sweep-able:** no — the right name depends on the role at each site.

---

## 16. Magic numbers / homeless constants

- **Bad:** an inline numeric literal in an expression (`x * 86_400`, `withTimeout(.seconds(20))`,
  `prefix(60)`), a global/file-scope `let`, or a `Constants.swift` dumping ground.
- **Why it spreads:** the literal is the shortest path to "it works"; the next agent copies the
  number and its meaning is lost (what is `86_400`?), and a global/`Constants` bag becomes the
  place every later constant gets dumped, untyped and unscoped.
- **Good:** a named `static let` on the type the value belongs to, narrowest access
  (`private`→`internal`→`public`), co-located with its use; `Duration` for time
  (`static let perRecordTimeout: Duration = .seconds(20)`). A case-less `enum` namespace ONLY
  for a bag of constants with no natural home type — never a `Constants.swift`. In-tree examples:
  `StowerConversationStateExtractor.reciprocityWindowDays`, `StowerCoreMLEmbedder.maxBatch`,
  `StowerRetriever.defaultRRFK`.
- **Caught by:** `judgment` today (AGENTS.md rule). The `no_magic_numbers` swiftlint gate (verified
  it fires on `* 86_400`, passes named `static let`s) is **scheduled** — enabled in the
  heuristic-removal plan's Task 9, once that pass eradicates the ~31 Sources literals, with a nested
  `Tests/.swiftlint.yml` opt-out (test fixtures legitimately use literal data, ~95 violations). Flip
  this to `gate` then. The "no global / no `Constants.swift` / static-let-on-type" half stays
  `judgment` (not mechanizable).
- **Sweep-able:** no — each literal needs a named home and a meaning (per-site judgment; the right
  scope/owner differs). Route recurrences here; fix by hand.

## 17. Ad-hoc gate instead of a `precheck.sh` static-source-guard family member

- **Bad:** enforcing a *"X is/isn't present, here"* source-tree fact with a one-off
  mechanism — a bespoke script, a new CI job, a hand-added `AGENTS.md` "do not…" rule —
  or with the wrong tool (a line-oriented `grep` for a region/block-scoped fact like
  "only inside `#if DEBUG`", which grep cannot track).
- **Why it spreads:** each ad-hoc gate is a parallel mechanism the next agent has to
  rediscover and imitate, so the enforcement story fragments; and a grep that can't see
  region structure silently passes the very case it was meant to catch (reports green
  while the rule isn't actually enforced).
- **Good:** add the next numbered member of the `Scripts/precheck.sh` `6x`
  static-source-guard family — a `# 6x — WHAT, WHY` block that does
  `echo "ERROR: <what + fix>" >&2; exit 1` on violation, anchored to real call sites.
  Pick the tool by the assertion's shape: **grep** (`grep -RInE`) for line-local facts;
  **awk** for region/block-scoped facts ("only inside a `#if DEBUG` region," "only
  inside a named pbxproj `XCBuildConfiguration` block"). Polarity = which outcome trips
  `exit 1`: must-be-**absent** → a match fails; must-be-**present** → a no-match fails.
  No external deps (no plutil/jq/python). In-tree members: `6a–6g` (module/UI
  boundaries, chat.db literal, no-logging), `6h` (`#if DEBUG` containment, awk), `6i`
  (`/health` wiring, grep), `6j` (no `DEBUG` in any Xcode Release config, awk).
- **Caught by:** `gate` — the family lives in `precheck.sh` (runs every commit + CI), so
  each member is enforced both places. The *convention* (add a member, don't fork a
  mechanism; grep-vs-awk by shape; polarity by which outcome fails) is `judgment`,
  documented in `AGENTS.md` "Static source guards".
- **Sweep-able:** no — each guard asserts a different fact with a different tool; the fix
  is to author the correct family member by hand, never a mechanical replace.

## How to add an entry

Append a numbered section in the same shape: **Bad / Why it spreads / Good / Caught
by / Sweep-able**. New entries usually arrive via `harden-guardrail` after a finding
recurs ≥2×. If the new rule is mechanizable, the same pass that adds the entry should
add the `gate` (swiftlint/swift-format rule or `precheck.sh` grep) so **Caught by**
can say `gate`, not `judgment`. Set **Sweep-able** honestly: `yes` only when one
repo-wide find-and-replace to the single good form is meaningful. A pattern only
counts as eliminated when an automated check rejects it, or (for sweep-able entries)
a sweep has removed every existing instance.
