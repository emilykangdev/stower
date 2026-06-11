# Plan: <one-line headline — what this plan delivers>

Flavor: feature | bugfix | refactor   ·   Date: YYYY-MM-DD   ·   Brief: <path or "n/a">

A plan is the contract the implementer signs against. Everything below exists to prevent vibe code: parallel helpers, scope drift, narration comments, untested invariants, "while I'm here" rewrites. If a section feels like ceremony for *this* plan, write `n/a — <reason>` rather than leaving it blank or filling it with filler.

## Goal

<2–4 sentences. What concrete user-visible or system-visible change ships when this plan is done. State the smallest version that delivers the value — not the cleanest, not the most general.>

## Non-goals

<Explicit list of things this plan does **not** do, especially adjacent improvements the implementer might be tempted to fold in. Each line is a "no" the reviewer can hold the implementer to.>

- <Adjacent feature that looks related — call it out as deferred / out-of-scope.>
- <Refactor that's tempting while touching this code — out unless it's strictly required.>
- <Surface or platform this plan does not extend to.>

## Why

<The motivating problem. What breaks or feels wrong today, who notices, and which failure modes this resolves. Reference prior briefs / decisions instead of re-litigating.>

1. **<Failure mode or unmet need 1>.** <Brief description.>
2. **<Failure mode or unmet need 2>.** <Brief description.>

## What

### User-visible behavior

- **<Surface 1>**: <what the user sees, when, and the trigger.>
- **<Surface 2>**: <same shape.>
- **Both surfaces**: <invariants that hold across surfaces — same wording, same typography, etc.>

### Technical requirements

- <New function / module / type to add, with file path. Justify why it can't reuse something in §Reuse inventory.>
- <Existing call sites to replace or migrate (with file:line refs).>
- <New component / route / handler, with file path.>
- <Wiring requirements: state, store selectors, IPC, etc.>
- <Styling / CSS / asset changes.>

### Success criteria

- [ ] <User-observable behavior 1.>
- [ ] <User-observable behavior 2.>
- [ ] <Edge case / format detail.>
- [ ] <Single-source-of-truth claim — "no other inline copies of X remain".>
- [ ] <Each §Invariant below has a corresponding test that passes.>
- [ ] Typecheck + lint + smoke / test commands pass.

## §Surface

What external state this implementation touches, and the failure mode if any touch goes wrong. §Surface is what's AT STAKE during; §Invariants below is what must be TRUE after. One bullet per touch.

- **<Filesystem path>** — read/write/create/delete; gitignored? committed by accident risk?
- **<CLI tool invoked>** — assumed cwd, link state, auth state; failure mode if the assumption is wrong (e.g. `railway` linked to prod → wrong-target wipe).
- **<Secret in flight>** — argv vs stdin vs env vs file vs log; where it could leak to `ps`, recordings, screen-shares.
- **<Source-of-truth semantics>** — additive (only adds keys) vs replace (key removed from input → removed downstream). State which and why.
- **<Edge / empty-input case>** — what happens on the minimal / empty / fresh state (e.g. fresh Railway env with only platform vars).
- **<Claim about other code>** — what I'm asserting (e.g. "TIMEBOX_VAULT_SUFFIX scopes the vault"); file:line where the claim is grounded.

Required for plans that add or change scripts, deploy steps, anything mutating ambient state (CLI links, cwd, secrets, filesystem outside the repo), or anything making claims about how other parts of the codebase behave. 5–10 bullets.

## §Invariants and Tests

Per AGENTS.md "Plans must specify invariants, not just steps", and must come with tests. Include test cases for each invariant.

**Check `docs/info/` FIRST.** Before writing any invariant, search `docs/info/` for an existing doc that already settles this property. If one does, the invariant MUST cite that doc as the authority and frame its test as the executable regression guard for the already-acknowledged rule — do NOT re-derive, re-argue, or re-declare a decision the docs already made. (Example: refresh-token rotation durability is settled in `docs/info/channel-renewal-vs-token-rotation.md`; a plan references it, it does not re-litigate the tx boundary.) Only invariants genuinely NEW to this work — a failure mode *this change* introduces — get stated fresh. This stops the same decisions from resurfacing across plans as if new.

Put it all in a table with columns: Invariant |	Test |	Threat it closes |	Enforced by. This is an excellent example of a plan: https://github.com/emilykangdev/projects-history/blob/main/time-box/v2-encryption-05-27-to-06-01-2026/done-plans/2026-05-28-v2-encryption-substrate.md

<More invariants here if there are any. Plans touching auth, credentials, money, async/concurrency, persistent state, or user-visible behavior should have 5–10 lines of invariants minimum.>

## All Needed Context

### Documentation & References

```yaml
- file: <path/to/related/brief-or-doc.md>
  why: <settled decisions; do not re-litigate>

- file: <path/to/source/file.ts>
  lines: <range — verify these lines still match at plan-write time; stale refs send the implementer to the wrong spot>
  why: <what lives here and why the implementer needs to read it>

- file: <path/to/related/component.tsx>
  lines: <range>
  why: <…>
```

### Reuse inventory

Existing primitives the implementer **must** reuse rather than recreate. The point is to head off parallel helpers, duplicated types, and re-derived constants before they happen. If something on this list ends up not used, that's a signal to reconsider the approach, not to silently invent a sibling.

- **<existing function name>** at `<file:lines>` — use for <what>. Do **not** write a sibling that does the same thing.
- **<existing type / enum>** at `<file:lines>` — extend or import; do not redeclare.
- **<existing component / hook>** at `<file:lines>` — wrap or compose; do not fork.
- **<existing constant / token>** at `<file:lines>` — read; do not inline a copy.

### Note on framework conventions / globals

- <Globalized APIs available without import — e.g. Temporal, $globalLogger.>
- <Project-wide patterns the implementer should match — e.g. five-layer IPC discipline, single-source-of-truth selectors.>

### Known gotchas

```typescript
// 1. <Gotcha — concrete failure mode with the wrong shape and the right shape.>

// 2. <Off-by-one / timezone / locale trap and how to dodge it.>

// 3. <Layout / CSS quirk in the parent that affects spacing or sizing.>

// 4. <Race condition or ordering subtlety; whether we accept it.>

// 5. <Naming collision / variable shadowing to watch for.>
```

### Considered and rejected

Approaches that were on the table and got ruled out. Logging these here stops the implementer (or a future Codex pass) from quietly re-adding a previously-rejected shape.

- **<Alternative approach 1>.** Rejected because <reason — usually points to a principle, a past incident, or a measurable cost>.
- **<Alternative approach 2>.** Rejected because <…>.

## Files Being Changed

```
<repo-root-relative path>/
├── <subdir>/
│   ├── <NewFile.tsx>                     ← NEW       (<one-line purpose>)
│   ├── <ModifiedFile.tsx>                ← MODIFIED  (<one-line summary of edit>)
│   ├── <AnotherModified.tsx>             ← MODIFIED  (<…>)
│   └── <OldFile.tsx>                     ← DELETED   (<replaced by NewFile.tsx>)
└── <styles-or-config>                    ← MODIFIED  (<…>)
```

<If the file count climbs past ~6 NEW files, stop and reconsider — that's usually a signal the plan is doing two things and should be split, or that something on the §Reuse inventory was overlooked.>

## Architecture Overview

<ASCII diagram of the data/control flow. Show: single source of truth → call sites → component(s) → rendered surface(s). Mark who reads vs. writes. Use it to make the symmetry (or asymmetry) visible at a glance.>

```
              <singleSourceOfTruth()>
                       │
              ┌────────┴─────────┐
              ▼                  ▼
        <call site 1>      <call site 2>
              │                  │
              ▼                  ▼
         <effect 1>          <effect 2>
                                 │
                                 ▼
                          <rendered output>
```

<1–2 sentences describing the shape — why it's small, what stays simple, and which boundary is the irreducible complexity.>

## Tasks (in implementation order)

Each task should be commit-sized: one concern, one verification step, leaves the tree typechecking. If a task can't fit that shape, split it.

- [ ] **Task 1 — <verb-led title>.** <What changes; which file(s) from §Files Being Changed.>
  - Verify: <typecheck / smoke / grep command that confirms this task alone is correct.>
- [ ] **Task 2 — <…>.**
  - Verify: <…>
- [ ] **Task N — Diff hostility pass.** Re-read the full diff end-to-end. Delete narration comments, single-use helpers, dead branches, leftover imports, `// removed: …` tombstones. AGENTS.md "Minimal Changes / No Slop" applies.

## Final Validation Checklist

```bash
# From the repo root.

# 1. Typecheck — catches signature drift.
<typecheck command>

# 2. Lint — AGENTS.md quality gate.
<lint command>

# 3. Test — invariant tests from §Invariants must pass.
<test command>

# 4. Single-source-of-truth grep — should return only <expected file>.
<grep command>

# 5. Diff hostility — `git diff <base>...HEAD` and cut anything the current implementation doesn't need.
git diff <base>...HEAD
```

- [ ] All §Invariants have a passing test.
- [ ] No `as any`, `as unknown as X`, `@ts-ignore`, `@ts-expect-error` introduced (AGENTS.md TypeScript Strictness).
- [ ] No narration comments, no `// added for X`, no commented-out code.
- [ ] No single-use helpers; no backwards-compat shims for code deleted in this same PR.
- [ ] Every file in §Files Being Changed actually changed; no untouched entries left in the table.

## Open questions

Known unknowns the implementer must surface (ask the user) rather than guess. Empty is fine — `n/a` if there are none. **Not** a parking lot for "future work" — that goes in §Non-goals.

- <Ambiguity 1 — what's unclear, and what the implementer should do if it comes up mid-implementation.>
- <Ambiguity 2 — …>
