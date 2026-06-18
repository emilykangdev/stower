# Stower — The Mac App Contract

> **Breaking contract delta (2026-06-15, FM-only judged-only engine — landed).** The app branch
> must absorb all of this. Most are compile-loud; the silent one is behavioral — there is no
> instant board, so the app must show a loading screen at cold start.
>
> | Change | Old | New |
> |---|---|---|
> | Judge mode | `StowerDebtConfig.judgeMode` / `StowerReplyJudgeMode` | **removed** (one judge) |
> | Verdict source | `verdictSource` on the public row; `.heuristic`/`.languageModel` | **removed from the public row** |
> | Row verdict fields | `expectsReply` + `verdictSource` on the row | **removed**; `isAuthoritative` / a pending placeholder / `reason` not added; keep `replyExpectationConfidence` |
> | Unjudged rows | a cache miss became a heuristic row | **never served** — judged-only board |
> | Neglected | ranked, never filtered ("you owe an ack regardless") | **gates** on the model's should-respond verdict |
> | Unavailable model | (n/a — degraded to heuristic) | `loadDebtBoard` / `refreshJudgments` throw `languageModelUnavailable(StowerModelUnavailableReason)` |
> | Availability check | (none) | public `modelAvailability() async -> StowerModelAvailability` |
> | Refresh summary | `init(changedChatIDs:)` + `changedCount` | `init(changedChatIDs:judgedCount:failedCount:totalCount:)` + public `judgedCount`/`failedCount`/`totalCount`; `changedCount` retained |
> | Refresh return | `async -> StowerRefreshSummary` | `async throws -> StowerRefreshSummary?` (`nil` = coalesced; throws when unavailable) |
> | Model identity | (n/a — implicit) | **judge-owned** — the judge folds its own model-identity epoch into the verdict cache; the app supplies no model argument on the `StowerDebtBoardProvider` init |
> | Cold start | paint immediately | **loading screen** until `judged + failed == total`, then board / "all caught up" |
>
> `StowerReplyExpectation` and `StowerReplyJudgeSource` are now `internal` — no public API returns
> them; the app uses `StowerDebtItem` only. The heuristic judge, the `judgeMode` knob, the
> `.heuristic` source token, and the legacy reply-listing CLI subcommand are deleted. There is
> **no heuristic fallback** — an unsupported Mac is routed to an onboarding/unsupported screen,
> never given a fake board.

What the StowerMac app links, what it must understand, and where the boundary
sits between engine and UI. This is the seam the app plans against so the app
branch and the library branches can move in parallel without colliding.

> The app is a **client of two Swift libraries** — `StowerCore` and
> `StowerMessages`. It never opens `chat.db`, never touches the index DB or the
> verdict cache directly, never imports `GRDB` or PhotoKit. Everything the app
> needs is a `public` symbol on a facade below. If the app reaches past a
> facade, that's the bug — not a missing feature.

---

## 1. The product surface and the capability beneath it

v1 is **one product** — the relationship-debt board — with search/read as a
**capability** the user acts through. Both sit on one data source (`chat.db`,
read-only). Don't read this as "two co-equal features"; the board is the front
door, search is a power tool inside it. (See [product vision](productvision.md).)

| | Role | Job-to-be-done | Library entry point | Status |
|---|---|---|---|---|
| **The product** | home surface | "Who am I dropping the ball on — and get me into that thread to fix it" | `StowerDebtBoardProviding` (Messages) | built (this branch) |
| **The capability** | act / reach | "Jump to any conversation and read it fast" (and recall falls out) | `StowerIndex` (Core) + `StowerChatDatabaseReader` (Messages) | built |

They share the same `chat.db` snapshot machinery and the same permission gates,
but they are independent reads — neither depends on the other. The app opens onto
the board; search and the thread view exist to act on a row, not as the front
door.

---

## 2. The dependency contract (one-way door — lock this first)

```
StowerMac (app)  ──►  StowerMessages  ──►  StowerCore
       │                                       ▲
       └───────────────────────────────────────┘
```

- The app depends **into** the libraries; nothing depends back out.
- The app links `StowerCore` and `StowerMessages`. It does **not** link
  `StowerPhotos` (that's the future iOS app) and must never transitively pull it
  in — keep the import list explicit.
- The app holds **no `GRDB`, no PhotoKit, no `FoundationModels`** import. Those
  are engine-internal. The app sees Swift value types and two actors.
- **Why this is the one-way door:** the facade shape is what the app builds its
  view models, navigation, and refresh loop against. Widening a value type later
  is additive and cheap; changing a method signature or moving a read behind a
  different actor ripples through every call site in the app. Get the *method
  surface* right now; let the *value fields* grow.

---

## 3. The product — the relationship-debt board

The whole consumable surface is one protocol. Concrete type:
`StowerDebtBoardProvider` (an `actor` conforming to `StowerDebtBoardProviding`).

### Construction (what the app instantiates once and holds)

```swift
let provider = StowerDebtBoardProvider(
    sourceURL: .defaultSourceURL,         // the chat.db to read
    contactsResolver: .live,              // name enrichment; degrades on denial
    cacheURL: .defaultCacheURL,           // verdict cache; nil/fault → empty board until refresh rebuilds
    windowDays: 180                       // how far back facts are read (NOT per-call)
)
```

`windowDays` is a **construction** concern, not a per-call knob. It must be ≥ any
`unansweredForDays` the app will ask for, or `loadDebtBoard` throws
`invalidArgument` (fail-loud, by design — widen the window).

The app supplies **no model argument** — model and prompt selection are the
judge's concern. The judge owns its own cache-invalidation epoch (folded with its
prompt into the verdict-cache `judge_version`); changing the validated judge
behavior/prompt/model invalidates every cache hit, so rows disappear until
re-judged — treat the first load after such a change like a cold start / re-warm
(loading screen, not "all caught up"). The epoch is never derived from the OS
version, so a silent OS model revision never discards verdicts.

### The four methods

```swift
func modelAvailability() async -> StowerModelAvailability
func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard
func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage]
func refreshJudgments(config: StowerDebtConfig, now: Date) async throws -> StowerRefreshSummary?
```

`modelAvailability()` is the cheap startup preflight the app calls BEFORE any
board work. `refreshJudgments` returns `nil` only when coalesced (a pass is
already running) and *throws* `languageModelUnavailable` when the model is
unavailable.

### `StowerDebtBoard` — the two lenses, pre-ordered and judged-only

```
StowerDebtBoard
 ├─ neglected: [StowerDebtItem]   // counterpart acted last — GATED by direction, ranked
 └─ ghosted:   [StowerDebtItem]   // you acted last on a statement worth a reply — GATED then ranked
```

- **Judged-only.** A conversation appears only once the on-device model has judged
  it and a trusted verdict is cached. An unjudged or cache-miss conversation is
  invisible — never a placeholder row.
- **Both lenses gate on the model's should-respond verdict, differing only by
  direction.** Neglected (they sent last) gates on the should-respond boolean and
  ranks by recency. Ghosted (you sent last) additionally gates on
  `replyExpectationConfidence >= ghostGateThreshold`, because "I sent last" is
  noisier and would flood without it.
- **The app re-sorts neither lens and re-filters neither.** That logic is the
  product; duplicating it in the UI is how the two drift.

### `StowerDebtItem` — one collapsed row (same shape for both lenses)

Carries: `chatID`, `chatTitle`, `counterpart`, `counterpartHandle`,
`lastMessageKind`, `lastMessageText?`, `lastMessageTimestamp`, `deepLink?`,
`replyExpectationConfidence`. **No `expectsReply`, `verdictSource`,
`isAuthoritative`, a pending discriminator, or `reason`** — every served row is
already a trusted verdict, so `replyExpectationConfidence` is display metadata,
not a gate the app re-applies.

App-side rules baked into the contract:
- A **non-text last act** comes through with `lastMessageText == nil` and
  `lastMessageKind` set — render it ("📷 Photo"), never suppress it.
- **"Unanswered for N days" is the app's to derive** from
  `lastMessageTimestamp` + `now`. The engine gives the timestamp, not the string.
- `deepLink` may be `nil` — have a fallback (open the thread in-app).
- `counterpartHandle` is a display fallback, **not** a dedupe key — use `chatID`.

### `StowerDebtConfig` — per-call knobs (cheap to flip)

`unansweredForDays`, `minimumReciprocity` (default 1), `ghostGateThreshold`
(default 0.5). There is **no `judgeMode`** — one judge. Flipping a runtime filter
(`unansweredForDays`, `ghostGateThreshold`) re-runs only the gate+rank over
already-cached verdicts — **it never re-invokes the model.** So a settings slider
is instant; wire it straight to a reload.

---

## 4. The capability — Search & Read

Not the front door — the tool the user acts *through*: jump to any conversation,
read it in-app, and recall ("what address did Sarah send?") falls out for free.
A board row's tap-through thread read uses the same `recentMessages` /
`threadMessages` path.

**Index lifecycle (`StowerCore.StowerIndex`, actor):**
- `init(path:)` — opens/creates the persistent FTS5 search DB (app picks the
  path, e.g. Application Support).
- `replaceAll(with:)` — the app's **ingest pass**: read messages via the adapter
  (below), hand `StowerIndexedItem`s in, one rebuild transaction. The app owns
  *when* to re-ingest (launch, periodic, on-demand).
- `search(_:limit:) -> [StowerSearchResult]` — pre-ranked (`bm25(1.0, 0.25)`,
  timestamp tiebreak). The app does not re-rank.
- `StowerSearchResult.groupedByGroupID(...)` — bucket hits by thread/album while
  keeping rank, for a per-conversation result list.

**Read lifecycle (`StowerMessages.StowerChatDatabaseReader`):**
- `recentMessages(...)` / `threadMessages(chatID:limit:)` — the thread view, used
  both by search results and by a debt-board row tap-through. The app renders
  these; it never queries `chat.db` itself.

**App owns:** the search box, debounce, result UI, the in-app thread reader,
deep-link-out to Messages.app, and the ingest schedule.

---

## 5. The lifecycle the app MUST understand

This is the part that makes or breaks planning. Four lifecycles run underneath
the facade; the app's job is to drive them correctly, not re-implement them.

### 5a. The cold-start → warm → reload loop (loading screen, never instant board)

`loadDebtBoard` **never runs a model.** It reads the shared snapshot + any
*trusted* cached verdicts, excludes everything unjudged, and returns at
structural speed. At cold start nothing is judged yet, so it returns **empty
lists** — the app shows a **loading screen, never a raw empty board.** The real
model runs only in `refreshJudgments`, in the background.

The app's loop is therefore:

```
1. modelAvailability()             → route to board / onboarding / unsupported
2. loadDebtBoard(config, now)      → cold: empty → show loading screen (not empty board)
3. refreshJudgments(config, now)   → background; returns StowerRefreshSummary? (nil = coalesced)
4. for every non-nil summary       → clear loading when judgedCount + failedCount == totalCount
5. if summary.changedChatIDs != [] → loadDebtBoard again → judged rows now appear
```

Treat **completion** and **reload** as two separate signals off the same summary:
clear loading on `judgedCount + failedCount == totalCount` (**never**
`judgedCount == totalCount` — one permanently-failing record would hang the
spinner), and reload only when `changedChatIDs` is non-empty. A failures-only
complete pass clears loading without a reload; its failed records carry no verdict
and are re-judged on the next refresh the app schedules (bounded backoff, no busy
loop). **Never block first paint on `refreshJudgments`.**

### 5b. Model availability (typed, startup-first)

The app calls `modelAvailability() async -> StowerModelAvailability` at startup,
BEFORE any board work, and routes by the typed reason:

- `.available` → proceed to `loadDebtBoard`.
- `.unavailable(.deviceNotEligible)` → terminal unsupported screen.
- `.unavailable(.appleIntelligenceNotEnabled)` → enable-Apple-Intelligence screen.
- `.unavailable(.modelNotReady)` → downloading/preparing screen; retry later.
- `.unavailable(.unknown)` → generic on-device-model-unavailable screen.

The check is cheap and public — no entitlement, Info.plist string, prompt, FDA
prompt, or network call. **Availability is also enforced inside the engine:**
`loadDebtBoard` re-resolves availability on every call and throws
`languageModelUnavailable(reason)` BEFORE opening `chat.db`, so an unsupported or
AI-off machine never touches private Messages data — and a mid-session change
(AI turned off) surfaces on the next load/refresh as that throw. Every served row
is already a trusted on-device verdict, so there is no per-row trust flag to read.

### 5c. Permissions (one hard gate, one soft degrade)

| Permission | On absence | App contract |
|---|---|---|
| **Full Disk Access** | `loadDebtBoard` throws `StowerMessagesError.fullDiskAccessMissing` | **Hard gate.** The app must have an onboarding/empty state that catches this typed error and walks the user to System Settings. Nothing works without it. |
| **Contacts** | silently degrades — `counterpart` falls back to the raw handle | **Soft.** Never an error, never blocks the board. Names just look worse. Optional "improve names" prompt. |

`StowerMessagesError` is the typed error surface (`sourceNotFound`,
`fullDiskAccessMissing`, `unreadableSource`, `invalidSnapshot`, `invalidRow`,
`invalidArgument`). The app switches on it for its error UI.

### 5d. The snapshot & the cache (engine-owned, app-aware)

- **Snapshot:** the engine takes one read-only copy of `chat.db` (temporary,
  swept) and **reuses it** across loads and thread opens; `refreshJudgments`
  rebuilds it. So the board reflects messages **as of the last refresh**, not the
  instant of each load — new messages appear after the next `refreshJudgments`,
  not on a bare `loadDebtBoard`. The first load (and the first load after a
  refresh) does real snapshot I/O; repeat loads are cheap. Still prefer
  view-appear, pull-to-refresh, and after-a-refresh-summary over per-keystroke
  calls.
- **Cache:** the verdict cache (`reply-verdicts.sqlite` under Application Support)
  is **disposable** and the trust boundary — it rejects malformed payloads on
  write and resolves an unknown source token to a miss on read. Corruption/lock/
  migration failure is a miss, re-judged on the next refresh — it never crashes or
  blanks. The app treats the cache as invisible; it only observes its *effect*
  (judged rows appearing after a refresh). No plaintext is stored, but the app
  should still state "all on-device" honestly in its privacy copy.

---

## 6. Ownership boundary — engine vs app

| The engine owns (don't reimplement) | The app owns (don't push down) |
|---|---|
| Facts extraction from `chat.db` | View models / SwiftUI state |
| Reply-expectation judgment (on-device model) | "Unanswered for N days" copy |
| Gating + ranking of both lenses (judged-only) | Navigation, the in-app thread reader |
| Typed model-availability resolution | Opening `deepLink` / Messages.app fallback |
| The verdict cache + snapshot lifecycle | The refresh **schedule** + retry backoff |
| Contacts enrichment | Permission UI / onboarding flow |
| Pre-ordering both lenses | Settings → `StowerDebtConfig` knobs |
| Returning honest judged/failed/total counts | Empty / error / loading / "all caught up" states |

The cut: **the engine decides *what's true and in what order*; the app decides
*how it looks, when it refreshes, and how the user navigates*.**

---

## 7. Contract decisions still open for the app team

Frame each as one-way (lock now) vs two-way (decide fast, iterate):

- **One-way — the method surface of `StowerDebtBoardProviding`.** If the app
  needs anything the three methods don't give (e.g. "mark as handled",
  per-row dismiss, a combined search+board read), surface it *now* so it's
  designed into the facade, not bolted on. Adding a method later is a library
  release the app must wait on.
- **Two-way — the refresh schedule.** On-appear? Timer? On-focus? Pick one,
  ship, tune. Cheap to change; don't over-deliberate.
- **Two-way — the cold-start loading / "all caught up" UI.** Progressive reveal
  vs a %-threshold spinner is app-owned; try one and iterate.
- **Two-way — default `StowerDebtConfig` values** (`unansweredForDays`,
  `ghostGateThreshold`). Ship the defaults, watch, adjust.

**Settled (2026-06-15) — the debt board is the product; search + thread-read is a
capability within it, and the board is the front door.** Not an open decision;
the app's home surface is the board. The one thing left to *validate* (not
decide) is the felt-frequency risk the vision doc flags — the board is a
daily/weekly "who am I forgetting" glance, not a many-times-daily tool. Watch
that with real users; it's a learn-by-shipping question, not a blocker.

---

## 8. The 60-second version for an app planner

1. Link `StowerCore` + `StowerMessages`. Import nothing else from the engine.
2. The **home surface is the debt board** (`StowerDebtBoardProvider`); search
   (`StowerIndex.search`) + thread-read are the capability you act *through*, not
   the front door. Both reads are pre-ranked — never re-sort.
3. Debt board loop: **`modelAvailability()` → `loadDebtBoard` (cold = empty →
   loading screen) → `refreshJudgments` (bg) → clear loading at
   `judged+failed==total`, reload when `changedChatIDs` is non-empty.** Never
   block paint on the model; never show a raw empty board at cold start.
4. Model availability is a typed, public startup check; an unavailable model
   throws `languageModelUnavailable` before `chat.db` opens. Full Disk Access is a
   hard, typed gate — build the onboarding for it. Contacts is soft. The cache and
   snapshot manage themselves.
5. Engine decides truth + order; app decides looks + timing + navigation.
   Anything the facade doesn't expose is a library change — raise it before you
   plan around it.

> **App-side shapes:** the precise dummy-provider shapes (provider protocol, value
> types, the `StowerStartupState` machine, per-reason routing, and dummy-data
> scenarios) the app builds against live in `tmp/briefs/macapp-frozen-contract.md`.
> This doc and that frozen contract describe the same as-built engine.
