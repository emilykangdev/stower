# Contributing to Stower

Thanks for helping build Stower. The bar is small, reviewable changes that
keep the guardrails green.

## Before you commit

- Run `./Scripts/precheck.sh`. It runs swift-format, SwiftLint, `swift build`,
  `swift test`, and the module-boundary checks. It must exit 0.
- Install the pre-commit hook once with `./Scripts/install-hooks.sh` so the
  check runs automatically on every commit (works in regular clones and git
  worktrees).
- Keep commits scoped: one commit, one concern. Do not refactor unrelated
  code while landing a feature.

## Tooling

- Swift 6.3.1 or later (`swift --version`).
- `brew install swift-format swiftlint` for the lint gate.
- `swift test` (Swift Testing) requires full Xcode locally, or the framework
  flags that `Scripts/precheck.sh` injects automatically under Command Line
  Tools. CI uses `macos-15`, where plain `swift test` works.

## AI-assisted contributions

If a change was substantially AI-generated, add an `Assisted-by:` trailer to
the commit message naming the tool. See `AI_POLICY.md` for the full policy and
`CLAUDE.md` for the agent rule set.

## Conventions

- Public top-level declarations in a `Stower*` module begin with `Stower`.
- New tests use Swift Testing (`@Test`, `#expect`), not XCTest.
- No `try!` or force-unwraps. No doc-comment-less `public` declarations.

See `CLAUDE.md` for the complete, prohibitive rule set.
