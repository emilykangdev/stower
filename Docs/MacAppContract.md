# Stower — The Mac App Contract

What the StowerMac app links, what it must understand, and where the boundary
sits between engine and UI. This is the seam the app plans against so the app
branch and the library branches can move in parallel without colliding.

> The app is a **client of two Swift libraries** — `StowerCore` and
> `StowerMessages`. It never opens `chat.db`, never touches the index DB or the
> verdict cache directly, never imports `GRDB` or PhotoKit. Everything the app
> needs is a `public` symbol on a facade below. If the app reaches past a
> facade, that's the bug — not a missing feature.

---

## 1. The two surfaces the app consumes

Stower's v1 is two jobs sharing one data source (`chat.db`, read-only):

| Surface | Job-to-be-done | Library entry point | Status |
|---|---|---|---|
| **A — Search & Read** | "Get me to the right conversation and let me read it, fast" (the [product vision](productvision.md)) | `StowerIndex` (Core) + `StowerChatDatabaseReader` (Messages) | built |
| **B — Relationship-debt board** | "Who do I owe / who ghosted me" | `StowerDebtBoardProviding` (Messages) | built (this branch) |

The app composes both. They share the same `chat.db` snapshot machinery and the
same permission gates, but they are independent reads — neither depends on the
other.

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

## 3. Surface A — Search & Read

The original v1 product: type a name/snippet → land in the thread → read it
inside Stower.

**Index lifecycle (`StowerCore.StowerIndex`, actor):**
- `init(path:)` — opens/creates the persistent FTS5 search DB (app picks the
  path, e.g. Application Support).
- `replaceAll(with:)` — the app's **ingest pass**: read messages via the adapter
  (below), hand `StowerIndexedItem`s in, one rebuild transaction. The app owns
  *when* to re-ingest (launch, periodic, on-demand).
- `search(_:limit:) -> [StowerSearchResult]` — the entry mechanism. Pre-ranked
  (`bm25(1.0, 0.25)`, timestamp tiebreak). The app does not re-rank.
- `StowerSearchResult.groupedByGroupID(...)` — bucket hits by thread/album while
  keeping rank, for a per-conversation result list.

**Read lifecycle (`StowerMessages.StowerChatDatabaseReader`):**
- `recentMessages(...)` / `threadMessages(chatID:limit:)` — the thread view. The
  app renders these; it never queries `chat.db` itself.

**App owns:** the search box, debounce, result UI, the in-app thread reader,
deep-link-out to Messages.app, and the ingest schedule.

---

## 4. Surface B — The relationship-debt board

The whole consumable surface is one protocol. Concrete type:
`StowerDebtBoardProvider` (an `actor` conforming to `StowerDebtBoardProviding`).

### Construction (what the app instantiates once and holds)

```swift
let provider = StowerDebtBoardProvider(
    sourceURL: .defaultSourceURL,         // the chat.db to read
    contactsResolver: .live,              // name enrichment; degrades on denial
    cacheURL: .defaultCacheURL,           // verdict cache; nil/fault → heuristic board
    windowDays: 180                       // how far back facts are read (NOT per-call)
)
```

`windowDays` is a **construction** concern, not a per-call knob. It must be ≥ any
`unansweredForDays` the app will ask for, or `loadDebtBoard` throws
`invalidArgument` (fail-loud, by design — widen the window).

### The three methods

```swift
func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard
func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage]
func refreshJudgments(config: StowerDebtConfig, now: Date) async -> StowerRefreshSummary
```

### `StowerDebtBoard` — the two lenses, pre-ordered

```
StowerDebtBoard
 ├─ neglected: [StowerDebtItem]   // counterpart acted last — RANKED, never filtered
 └─ ghosted:   [StowerDebtItem]   // you acted last on a real ask — GATED then ranked
```

- **Neglected** = you owe at least an ack; never dropped. `expectsReply` floats
  real questions above chit-chat.
- **Ghosted** = you sent last on a real ask and got no reply. Gated on
  `expectsReply && replyExpectationConfidence >= ghostGateThreshold`, then ranked
  by recency. (Ungated it would flood with benign "I sent last" threads.)
- **The app re-sorts neither lens and re-filters neither.** That logic is the
  product; duplicating it in the UI is how the two drift.

### `StowerDebtItem` — one row (same shape for both lenses)

Carries: `chatID`, `chatTitle`, `counterpart`, `counterpartHandle`,
`lastMessageKind`, `lastMessageText?`, `lastMessageTimestamp`, `deepLink?`,
`expectsReply`, `replyExpectationConfidence`, `verdictSource`.

App-side rules baked into the contract:
- A **non-text last act** comes through with `lastMessageText == nil` and
  `lastMessageKind` set — render it ("📷 Photo"), never suppress it.
- **"Unanswered for N days" is the app's to derive** from
  `lastMessageTimestamp` + `now`. The engine gives the timestamp, not the string.
- `deepLink` may be `nil` — have a fallback (open the thread in-app).
- `counterpartHandle` is a display fallback, **not** a dedupe key — use `chatID`.

### `StowerDebtConfig` — per-call knobs (cheap to flip)

`unansweredForDays`, `minimumReciprocity` (default 1), `judgeMode` (default
`.automatic`), `ghostGateThreshold` (default 0.5). Flipping a runtime filter
(`unansweredForDays`, `ghostGateThreshold`) re-runs only the gate+rank over
already-cached verdicts — **it never re-invokes the model.** So a settings slider
is instant; wire it straight to a reload.

---

## 5. The lifecycle the app MUST understand

This is the part that makes or breaks planning. Four lifecycles run underneath
the facade; the app's job is to drive them correctly, not re-implement them.

### 5a. The load → refresh → reload loop (the "feels instant" pattern)

`loadDebtBoard` **never runs a model.** It reads a fresh snapshot + the inline
heuristic + any *cached* language-model verdicts, and returns at structural
speed (target p50 < 300ms). The real model only runs in `refreshJudgments`, in
the background.

The app's loop is therefore **two-phase**:

```
1. loadDebtBoard(config, now)      → paint immediately (heuristic / cached verdicts)
2. refreshJudgments(config, now)   → background; returns StowerRefreshSummary
3. if summary.changedCount > 0     → loadDebtBoard again → rows upgrade to .languageModel
```

`StowerRefreshSummary.changedChatIDs` tells the app *whether a reload is worth
it.* Empty summary (heuristic mode, model unavailable, or no cache) → don't
reload. **The app must never block first paint on `refreshJudgments`.** This is
the core UX invariant; building a single synchronous "load everything" path
defeats the whole design.

### 5b. Model availability (verdict trust)

`verdictSource` on each row is either `.heuristic` or `.languageModel`. Both
Apple's on-device FoundationModels *and* a future MLX judge report
`.languageModel`. **Trust `replyExpectationConfidence` only when
`verdictSource == .languageModel`.** Under `.automatic`, the engine uses the
model when the machine supports it (macOS 26 + Apple Intelligence on), else the
heuristic — transparently. The app shouldn't gate its own UI on OS version;
it reads `verdictSource` per row and trusts accordingly. (A subtle confidence
cue in the row UI — "AI-judged" vs not — is an app design call, see §7.)

### 5c. Permissions (one hard gate, one soft degrade)

| Permission | On absence | App contract |
|---|---|---|
| **Full Disk Access** | `loadDebtBoard` throws `StowerMessagesError.fullDiskAccessMissing` | **Hard gate.** The app must have an onboarding/empty state that catches this typed error and walks the user to System Settings. Nothing works without it. |
| **Contacts** | silently degrades — `counterpart` falls back to the raw handle | **Soft.** Never an error, never blocks the board. Names just look worse. Optional "improve names" prompt. |

`StowerMessagesError` is the typed error surface (`sourceNotFound`,
`fullDiskAccessMissing`, `unreadableSource`, `invalidSnapshot`, `invalidRow`,
`invalidArgument`). The app switches on it for its error UI.

### 5d. The snapshot & the cache (engine-owned, app-aware)

- **Snapshot:** every `loadDebtBoard` takes a *fresh* read-only copy of `chat.db`
  (temporary, swept). The app gets current data on every load for free — no
  manual invalidation. Cost: a load does real I/O, so don't call it on every
  keystroke; call it on view-appear, pull-to-refresh, and after a refresh
  summary.
- **Cache:** the language-model verdict cache (`reply-verdicts.sqlite` under
  Application Support) is **disposable**. Corruption/lock/migration failure
  degrades to a heuristic board — it never crashes or blanks. The app treats the
  cache as invisible; it only observes its *effect* (`.languageModel` rows
  appearing after a refresh). No plaintext is stored, but the app should still
  state "all on-device" honestly in its privacy copy.

---

## 6. Ownership boundary — engine vs app

| The engine owns (don't reimplement) | The app owns (don't push down) |
|---|---|
| Facts extraction from `chat.db` | View models / SwiftUI state |
| Reply-expectation judgment (heuristic + model) | "Unanswered for N days" copy |
| Ranking of Neglected | Navigation, the in-app thread reader |
| Gating + ranking of Ghosted | Opening `deepLink` / Messages.app fallback |
| The verdict cache + snapshot lifecycle | The refresh **schedule** (when to call) |
| Contacts enrichment | Permission UI / onboarding flow |
| Pre-ordering both lenses | Settings → `StowerDebtConfig` knobs |
| Picking the judge by mode + availability | Empty / error / loading states |

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
- **Two-way — surfacing `verdictSource` in the UI.** Whether/how to signal "AI
  judged this" vs heuristic is a design call; try one and iterate.
- **Two-way — default `StowerDebtConfig` values** (`unansweredForDays`,
  `ghostGateThreshold`). Ship the defaults, watch, adjust.
- **One-way-ish — whether the app ships Surface A, Surface B, or both in v1.**
  The product vision frames v1 as search+read (Surface A); the debt board
  (Surface B) is the newer, higher-judgment surface. That's a positioning /
  scope decision worth an explicit call before the app plan is written —
  not a thing to discover mid-build.

---

## 8. The 60-second version for an app planner

1. Link `StowerCore` + `StowerMessages`. Import nothing else from the engine.
2. Two reads: `StowerIndex.search` (navigate) and `StowerDebtBoardProvider`
   (debt board). Both pre-ranked — never re-sort.
3. Debt board loop: **`loadDebtBoard` (instant) → `refreshJudgments` (bg) →
   reload if the summary changed.** Never block paint on the model.
4. Full Disk Access is a hard, typed gate — build the onboarding for it.
   Contacts is soft. The cache and snapshot manage themselves.
5. Engine decides truth + order; app decides looks + timing + navigation.
   Anything the facade doesn't expose is a library change — raise it before you
   plan around it.
