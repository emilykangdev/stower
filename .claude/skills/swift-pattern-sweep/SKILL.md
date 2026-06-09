---
name: swift-pattern-sweep
description: Eradicate one named bad Swift pattern across the entire Stower repo and replace every instance with the single canonical good pattern from the catalog, so an inconsistent codebase becomes a consistent one. Use when a pattern recurs (found by swift-signal-review or noticed by hand) and you want it gone everywhere, or when asked to "sweep", "fix this everywhere", "remove all force-unwraps", "make this consistent across the codebase", or "eliminate this pattern".
---

# swift-pattern-sweep

Eliminate a bad pattern as soon as it appears, before it spreads. The rule from the
blog: if there is one bad pattern, that one bad pattern should be gone, replaced with
one good pattern plus the rule behind it. Inconsistency is what feeds the entropy
loop — a codebase showing two ways to do one thing teaches the next agent to pick the
worse one. A sweep collapses it back to one way.

Patterns and their canonical replacements live in `.claude/skills/SWIFT_PATTERNS.md`.
This skill does the repo-wide replacement; `swift-signal-review` finds; this fixes.

## Inputs

- **Which pattern.** A catalog entry number/name (e.g. "#13 catch-and-ignore"), or a
  description. If it is not in the catalog, stop and recommend adding it via
  `harden-guardrail` first — a sweep without a written rule is just a one-off edit.

## Steps

1. **Pin the target.** Read the catalog entry: the bad form, the one good form, and
   what catches it. The good form is the *only* replacement; do not introduce a second
   variant during the sweep.

2. **Find every instance.** `Grep` the bad shape across `Sources/` and `Tests/`. Be
   precise — match real Swift, not strings or comments that mention it (mirror how
   `precheck.sh` step 5 anchors its import checks). List every hit as `file:line`
   before changing anything, and show the list.

3. **Confirm scope.** If the sweep touches more than a handful of files, summarize the
   blast radius and confirm before editing. A sweep is a structural change.

4. **Replace, one pattern only.** Apply the canonical good form at every site. Do not
   fix unrelated things along the way — a sweep is itself a structural change and must
   not be mixed with behavioral changes (catalog #11). If a site genuinely needs a
   different fix, list it as an exception and leave it for a separate change.

5. **Verify with the gate.** `./Scripts/precheck.sh` must pass. If the pattern has a
   `gate` (a swiftlint/swift-format rule), the sweep is only done when the gate is
   green with zero remaining instances. If it is a `judgment` pattern, grep again to
   prove zero remain.

6. **Commit as a pure structural change.** One commit, one concern: "refactor: replace
   <bad> with <good> repo-wide". No feature work in the same commit. Add the
   `Assisted-by:` trailer per `AI_POLICY.md` if AI did the work. Do not use
   `--no-verify`.

7. **Close the loop.** If this pattern has no `gate` yet, recommend `harden-guardrail`
   so it can never reappear. A sweep removes today's instances; only a gate stops
   tomorrow's.

## Output format

```
## swift-pattern-sweep — #<n> <name>

Target (bad): <shape>
Canonical (good): <shape>   [from SWIFT_PATTERNS.md]

Instances found: <N> across <M> files
- Sources/...:line
- ...

Exceptions (left for separate change): <none | list>

Result: <N replaced>, gate PASS, 0 remaining.
Next: harden-guardrail to add a gate  |  gate already exists (rule X)
```

## Notes

- One pattern per sweep. Sweeping two patterns at once produces an unreviewable diff.
- Never weaken a test or delete coverage to make the sweep pass. If the good pattern
  breaks a test, the test was asserting the bad pattern — fix the assertion, don't
  delete it.
- If the sweep reveals the "good" pattern is wrong or has its own edge cases, stop and
  revisit the catalog entry via `harden-guardrail` before continuing.
