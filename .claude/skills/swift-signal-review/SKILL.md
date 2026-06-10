---
name: swift-signal-review
description: Review the current Swift diff for bad patterns and Stower architecture violations before they spread. Runs the objective gate (precheck.sh) first, then a judgment-level pattern review against the shared catalog, and flags any finding that recurs so it can become a rule. Use after writing or changing Swift in this repo, before committing or opening a PR, or when asked to "review", "check the diff", "look for bad patterns", or "signal review".
---

# swift-signal-review

Notice bad Swift patterns in a change before they get copied. This is the "judging"
half of signal coding: the objective gate (`precheck.sh`) proves the code compiles,
formats, lints, tests, and respects module boundaries. This skill catches what the
gate can't — the judgment-level patterns that an AI propagates because they read as
"locally correct."

The catalog of patterns lives in `.claude/skills/SWIFT_PATTERNS.md`. Read it first;
it is the single source of truth. Do not invent findings outside it without saying so.

## Steps

1. **Scope the diff.** Determine what changed:
   ```
   git diff origin/main... --stat
   git diff origin/main...
   ```
   If the user points at a specific commit/PR/range, use that instead. Review only the
   changed Swift, not the whole tree (that is `swift-pattern-sweep`'s job).

2. **Run the objective gate first.** `./Scripts/precheck.sh`. If it fails, stop and
   report the failure — there is no point reviewing patterns in code that doesn't pass
   the gate. Do not comment out or weaken a rule to make it pass; fix the cause.

3. **Read the catalog.** Open `.claude/skills/SWIFT_PATTERNS.md`. For each changed
   hunk, check it against every `judgment` entry (the `gate` entries are already
   covered by step 2, but call out if a gate finding suggests a deeper pattern).
   Pay special attention to the entries with no automated check:
   - #5 loose access control (the gate only checks an ACL exists, not that it's narrow)
   - #7 XCTest in new tests
   - #9 bypassing `IndexedItem`
   - #10 public name without `Stower` prefix
   - #11 mixed structural + behavioral change in one commit
   - #12 real Photos/Messages data in fixtures/logs/prompts
   - #13 catch-and-ignore
   - #14 new `Utilities`/`Common` module or fourth adapter
   - #15 naming by type instead of role

4. **Reject-on-sight checks.** Independent of the catalog, flag and reject:
   - an unexpected loop (functionality the plan didn't ask for),
   - functionality nobody asked for (scope creep),
   - a test weakened, skipped, or deleted to make something pass. A test that exits
     green when a prerequisite is missing is a disabled guardrail, not a passing test;
     flag it.

5. **Detect recurrence.** For each finding, check whether the same pattern already
   exists elsewhere in the tree (`Grep` the offending shape). Recurrence is the
   signal that converts a nitpick into a rule:
   - **1 occurrence** → fix it inline, note it.
   - **≥2 occurrences** → this is a pattern, not a one-off. Route by the catalog
     entry's **Sweep-able** flag:
     - `Sweep-able: yes` → recommend `swift-pattern-sweep` to eradicate every
       instance, then `harden-guardrail` to add a gate so it can't return.
     - `Sweep-able: no` (judgment / process / architectural — e.g. #11, #12, #14) →
       do not recommend a sweep; there is no single mechanical replacement. Fix the
       instances in place and route to `harden-guardrail` (a gate where mechanizable,
       otherwise an `AGENTS.md` rule).

6. **Report.** Group findings by severity. For each: `file:line`, the catalog entry
   number (or "outside catalog"), the one-line fix, and whether it recurs. End with a
   clear verdict and the exact next action.

## Output format

```
## swift-signal-review

Gate: PASS | FAIL (precheck.sh)
Scope: <N files, M hunks> vs origin/main

### Must fix
- Sources/StowerMessages/Reader.swift:42 — [#13 catch-and-ignore] empty catch swallows
  a decode failure. Propagate with `throws`. Recurs: 3× (also Reader.swift:88, Store.swift:17)
  → run swift-pattern-sweep on #13, then harden-guardrail.

### Consider
- ...

### Verdict
<ship | fix-then-ship | reject> — <one sentence>
Next: <exact command or skill to run>
```

## Notes

- This skill only reads and reports. It does not edit. To apply fixes across the tree,
  hand off to `swift-pattern-sweep`. To make a finding permanent, hand off to
  `harden-guardrail`.
- Keep the review scoped to the diff. A clean, small review beats an exhaustive one the
  user won't read — the same reason plans are kept small.
- If you find a real bad pattern that is not in `SWIFT_PATTERNS.md`, say so explicitly
  and recommend adding it via `harden-guardrail`.
