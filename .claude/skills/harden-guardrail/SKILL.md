---
name: harden-guardrail
description: Turn a recurring code-review finding into a durable, automated guardrail for the Stower repo so the same class of mistake can't come back. Prefers an objective gate (swiftlint/swift-format rule or precheck.sh check) the AI can't argue with, then a prohibitive AGENTS.md rule, then a decision skill, and records the bad→good pair in the pattern catalog. Use during a retro, after a pattern recurs ≥2×, or when asked to "make this a rule", "harden this", "add a guardrail", "stop this coming back", or "turn this review comment into a rule".
---

# harden-guardrail

Build the thing that tells the AI whether its work is acceptable, automatically, every
time. This is the highest-leverage move in signal coding: a review comment fixes one
diff; a guardrail fixes the whole class. Recurrence ≥2× is what converts a nitpick
into a rule. The goal is to replace a "vibe" ("this looks off") with a signal the
agent can't argue with.

## The ladder (prefer the highest rung that fits)

Apply guardrails in this order. Higher rungs are more objective and need no human in
the loop; only drop down a rung when the pattern genuinely can't be mechanized.

1. **Objective gate — best.** The pattern is mechanically detectable, so make
   `precheck.sh` fail on it:
   - A swiftlint rule (enable an opt-in rule, add to `opt_in_rules`, or write a custom
     `custom_rules` regex in `.swiftlint.yml`).
   - A swift-format rule in `.swift-format`.
   - A grep step in `Scripts/precheck.sh` (mirror the anchored, `*.swift`-scoped style
     of the existing step 5 module-boundary checks so a comment or string can't trip a
     false positive).
   Why best: it runs on every commit and in CI, returns a binary signal, and can't be
   rubber-stamped. After adding it, the catalog entry's **Caught by** becomes `gate`.

2. **Prohibitive AGENTS.md rule — when judgment is required.** The pattern needs human
   reasoning to spot. Add a "Do not X" line to `AGENTS.md`. Phrase it prohibitively,
   not aspirationally — research shows prohibitive constraints help agents while
   positive directives ("follow good style") can hurt. Keep `AGENTS.md` tight; if it's
   getting long, tighten or merge rather than append endlessly.

3. **Decision skill — when the choice is genuinely nuanced.** The pattern is really a
   recurring *decision* with a right answer that depends on context (the canonical
   example: when to use one type vs another across a serialization boundary). Create a
   small skill that is the single source of truth for that decision, and reference it
   from `AGENTS.md` and the catalog. Only reach for this when a one-line rule can't
   capture the nuance — most findings stop at rung 1 or 2.

## Steps

1. **State the finding and prove recurrence.** Name the bad pattern and the good
   replacement. Show ≥2 instances (`Grep`). If it's a one-off, don't harden it yet —
   say so. Premature rules are the same mistake as premature skills.

2. **Record it in the catalog.** Add or update the entry in
   `.claude/skills/SWIFT_PATTERNS.md` (shape: **Bad / Why it spreads / Good / Caught
   by / Sweep-able**). Both review routing and `swift-pattern-sweep` depend on the
   `Sweep-able` field, so never omit it. The catalog is the source of truth; it gets
   the entry before any gate.

3. **Pick the highest rung that fits** and implement it:
   - Rung 1: edit `.swiftlint.yml` / `.swift-format` / `Scripts/precheck.sh`. Verify
     the new check actually fires on a known-bad sample and passes on good code. A gate
     that doesn't fail on the bad pattern is worse than none — it reports green while
     coverage isn't running.
   - Rung 2: add the prohibitive line to `AGENTS.md`.
   - Rung 3: scaffold the decision skill under `.claude/skills/<name>/SKILL.md`,
     reference it from `AGENTS.md` and the catalog.

4. **Eradicate existing instances.** A new gate or rule will fail (or want) the tree
   clean if old instances remain. If the catalog entry is `Sweep-able: yes`, hand off
   to `swift-pattern-sweep` (or sweep inline). If it is `Sweep-able: no`, fix the sites
   by hand — do not invoke the sweep, which refuses non-sweepable entries. Either way,
   confirm `./Scripts/precheck.sh` passes.

5. **Commit.** Keep the guardrail change separate from any feature work. Conventional
   message, e.g. "chore: add guardrail for <pattern>". Add `Assisted-by:` per
   `AI_POLICY.md`. No `--no-verify`.

## Output format

```
## harden-guardrail — <pattern>

Recurrence: <N instances> across <M files>  (proven, ≥2×)
Catalog: entry #<n> added/updated

Rung chosen: 1 gate | 2 AGENTS.md rule | 3 decision skill
Implemented:
- <file edited> — <what>
Verified: new check fails on bad sample, passes on good. precheck.sh PASS.

Existing instances: <swept via swift-pattern-sweep | none>
Next: <commit | sweep first>
```

## Notes

- Always prefer the gate. "Add a AGENTS.md rule" is the fallback for things that can't
  be mechanized, not the default — a rule in a doc still relies on the agent reading
  and honoring it, while a gate just fails.
- One guardrail per pass. Bundling several makes the change unreviewable.
- Revisit guardrails on a cadence (the weekly retro). A rule that no longer matches the
  code, or contradicts another rule, is worse than no rule — it quietly degrades every
  change that reads it. Delete stale ones.
- This skill is how the harness improves itself. Each finding it hardens is one class
  of mistake the codebase will never show the next agent.
