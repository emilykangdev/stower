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

---

## 1. Force unwrap and force try

- **Bad:** `let x = dict["k"]!`, `try! decoder.decode(...)`, `value as! Foo`.
- **Why it spreads:** the shortest path to "it compiles." Each one is a latent crash;
  copied into a hot path it becomes a class of crashes.
- **Good:** `guard let x = dict["k"] else { ... }`, `try` with a typed error,
  `guard let foo = value as? Foo else { ... }`.
- **Caught by:** `gate` — swift-format `NeverForceUnwrap` / `NeverUseForceTry`,
  swiftlint `force_unwrapping` / `force_cast` / `force_try`.

## 2. Deep nesting / high cyclomatic complexity

- **Bad:** stacked `if let` / `switch` / `for` pyramids; one function deciding many things.
- **Why it spreads:** AI adds "just one more branch" per prompt; complexity creeps
  past the point where the model can still reason about the function it wrote.
- **Good:** early-return `guard`; extract a named helper per concern; flatten with
  `map`/`compactMap`/`first(where:)`.
- **Caught by:** `gate` — swiftlint `cyclomatic_complexity` warning 8. If a function
  legitimately needs more, add `// swiftlint:disable:next` with a one-line reason.

## 3. Over-long functions

- **Bad:** a 60-line function body doing setup + work + formatting.
- **Why it spreads:** becomes the size template for the next function.
- **Good:** keep bodies under 40 lines; extract phases into named functions.
- **Caught by:** `gate` — swiftlint `function_body_length` warning 40.

## 4. Undocumented public API

- **Bad:** `public func search(...)` with no doc comment.
- **Why it spreads:** undocumented public surface is unstable surface; the next agent
  guesses intent and guesses wrong.
- **Good:** `///` one-line summary first, then params/returns. Triple-slash only.
- **Caught by:** `gate` — swift-format `AllPublicDeclarationsHaveDocumentation` +
  `BeginDocumentationCommentWithOneLineSummary`, swiftlint `missing_docs`.

## 5. Loose access control (public-by-default)

- **Bad:** marking new types/members `public` because the AI defaults to it.
- **Why it spreads:** every `public` is a promise; an accidental public surface gets
  depended on and can't be narrowed later.
- **Good:** strictest ACL that works. `internal` by default, `public` only when a
  cross-module consumer truly needs it. Prefer `private` to `fileprivate`.
- **Caught by:** `gate` — swiftlint `explicit_acl` / `explicit_top_level_acl`.

## 6. Block comments

- **Bad:** `/** ... */` doc blocks.
- **Good:** `///` triple-slash.
- **Caught by:** `gate` — swift-format `NoBlockComments` / `UseTripleSlashForDocumentationComments`.

## 7. XCTest in new tests

- **Bad:** `import XCTest`, `class FooTests: XCTestCase`, `XCTAssertEqual`.
- **Why it spreads:** mixing two test frameworks splits the conventions; the next
  test copies whichever it saw last.
- **Good:** Swift Testing — `@Test`, `@Suite`, `#expect`, `#require`. For struct
  diffs use `expectNoDifference` (swift-custom-dump).
- **Caught by:** `judgment` (no gate yet). Detect: `import XCTest` under `Tests/`.
  Strong candidate for `harden-guardrail` to add a precheck grep.

## 8. Module-boundary violation

- **Bad:** `import StowerPhotos`/`StowerMessages` inside `StowerCore`; adapters
  importing each other.
- **Why it spreads:** one back-arrow import collapses the whole dependency story; the
  layering stops being a constraint the AI can rely on.
- **Good:** dependency arrows point INTO `StowerCore`. Adapters never know about each
  other. Cross the boundary via the `IndexedItem` protocol.
- **Caught by:** `gate` — `Scripts/precheck.sh` step 5.

## 9. Bypassing IndexedItem

- **Bad:** adding records to the index with PhotoKit or chat.db/GRDB-specific types
  leaking into `StowerCore`.
- **Why it spreads:** the index gains a second ingestion path; new sources copy the
  leaky one instead of the protocol.
- **Good:** adapters produce values conforming to `StowerCore.IndexedItem`; the index
  only ever sees `IndexedItem`.
- **Caught by:** `judgment`.

## 10. Public name without `Stower` prefix

- **Bad:** `public struct SearchResult` at top level in a `Stower*` module.
- **Why it spreads:** breaks the swift-nio-style namespace convention; collisions and
  ambiguity follow.
- **Good:** `public struct StowerSearchResult`, or nest the type inside a `Stower*`
  type. Underscore-prefixed public names read as internal.
- **Caught by:** `judgment`.

## 11. Mixed structural + behavioral change in one commit

- **Bad:** a feature commit that also renames/moves/refactors unrelated code.
- **Why it spreads:** the diff becomes unreviewable, so it gets rubber-stamped, so the
  bad lines inside it ship. The blog's #1 lesson: a bad line of a plan becomes
  hundreds of bad lines of code.
- **Good:** one commit, one concern. Refactors ship separately from features.
- **Caught by:** `judgment`. Three things get a diff rejected on sight: an unexpected
  loop, functionality nobody asked for, a test weakened or deleted to make it pass.

## 12. Real Photos/Messages data in fixtures, logs, prompts

- **Bad:** committing real captions, real chat text, real attachments as test data;
  printing them in debug logs.
- **Why it spreads:** a privacy leak that becomes the fixture template.
- **Good:** synthetic fixtures only, generated in-test. Never real user data anywhere
  committed or logged.
- **Caught by:** `judgment`.

## 13. Catch-and-ignore

- **Bad:** `do { ... } catch { }` or `try?` that silently swallows a real failure.
- **Why it spreads:** the failure becomes invisible; the next agent assumes the call
  can't fail.
- **Good:** handle it, or propagate with `throws`. `try?` only when nil genuinely is
  the right, intended outcome (and say so).
- **Caught by:** `judgment`.

## 14. New `Utilities`/`Common` module or a fourth source adapter

- **Bad:** creating a grab-bag module, or a fourth `Sources/` adapter, mid-feature.
- **Why it spreads:** the grab-bag attracts everything; the architecture stops being
  legible.
- **Good:** shared code goes in `StowerCore`. New data sources go through
  discussion + brief + plan before any module exists.
- **Caught by:** `judgment`.

## 15. Naming by type instead of role

- **Bad:** `let string = ...`, `let widgetFactory: Supplier`.
- **Why it spreads:** every reader re-derives intent; clarity at the point of use rots.
- **Good:** name by role — `greeting`, `supplier`. Booleans read as assertions
  (`isEmpty`, `intersects`). Mutating/non-mutating pairs follow `-ed`/`-ing`.
  Anchor to Apple's API Design Guidelines.
- **Caught by:** `judgment`.

---

## How to add an entry

Append a numbered section in the same shape: **Bad / Why it spreads / Good / Caught
by**. New entries usually arrive via `harden-guardrail` after a finding recurs ≥2×.
If the new rule is mechanizable, the same pass that adds the entry should add the
`gate` (swiftlint/swift-format rule or `precheck.sh` grep) so **Caught by** can say
`gate`, not `judgment`. A pattern only counts as eliminated when an automated check
rejects it, or the catalog plus a sweep has removed every existing instance.
