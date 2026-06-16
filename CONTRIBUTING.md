# Contributing to Stower

> **Issues welcome; pull requests are not.** Stower is in early, solo
> development. **Bug reports, questions, and ideas via
> [issues](https://github.com/emilykangdev/stower/issues) are genuinely
> welcome.** External **pull requests are not accepted** right now and are closed
> automatically (see `.github/workflows/decline-external-prs.yml`) — please open
> an issue instead. This may change as the project matures.

The notes below are for the maintainer and AI agents working in the repo. The bar
is small, reviewable changes that keep the guardrails green.

## Before you commit

- Run `./Scripts/precheck.sh`. It runs swift-format, SwiftLint, `swift build`,
  `swift test`, and the module-boundary checks. It must exit 0.
- Install the git hooks once with `./Scripts/install-hooks.sh` (or run
  `./Scripts/new-worktree.sh`): pre-commit runs `precheck.sh` on every commit.
  Works in regular clones and git worktrees.
- When you open a PR, run `./Scripts/pre-pr.sh` (it opens the PR if needed, then
  fires the advisory `swift-signal-review` once, scoped to the PR's base). It is
  deliberately not a git hook — a push happens many times per branch, a PR once.
- Keep commits scoped: one commit, one concern. Do not refactor unrelated
  code while landing a feature.

## Tooling

- Swift 6.3.1 or later (`swift --version`).
- `brew install swift-format swiftlint` for the lint gate.
- `swift test` (Swift Testing) requires full Xcode locally, or the framework
  flags that `Scripts/precheck.sh` injects automatically under Command Line
  Tools. CI uses `macos-15`, where plain `swift test` works.

## AI-assisted contributions

Stower is built primarily by AI agents under the maintainer's review. No
per-commit AI attribution trailer is required. See `AGENTS.md` for the agent
rule set.

## Conventions

- Public top-level declarations in a `Stower*` module begin with `Stower`.
- New tests use Swift Testing (`@Test`, `#expect`), not XCTest.
- No `try!` or force-unwraps. No doc-comment-less `public` declarations.

See `AGENTS.md` for the complete, prohibitive rule set.
