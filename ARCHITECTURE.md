# Stower — Architecture at a glance

Diagrams, top to bottom: **the runtime lifecycle** (app launch → startup flow →
engine → background refresh), **how a query flows through the system today**, and
**the tables**. For the full per-table column detail and ownership/status notes,
see [`Docs/DataModel.md`](Docs/DataModel.md); this file is the bird's-eye view.

## Runtime lifecycle — launch, startup flow, and the engine

Two views of the same machine: a **call graph** (who calls whom, by file) and a
**state machine** (how the UI moves through screens and keeps running). The app
target imports only `StowerMacUI`; exactly four engine-coupled files —
`StowerMessagesStartupAdapter`, `StowerLiveBoardDataSource`,
`StowerMessagesComposition`, and `StowerMessagesMapping` — import the
`StowerMessages` engine (enforced by `precheck.sh` 6b). They are the
anti-corruption boundary that maps engine types to app-owned `StowerStartup*` /
`StowerBoard*` types; `StowerMessagesComposition` builds ONE
`StowerDebtBoardProvider` and injects it into both the startup adapter and the
board adapter, so the reader, verdict cache, and refresh coalescing are shared.

### Call graph — who calls whom on startup

```mermaid
flowchart TB
    subgraph app["StowerMac (app target) · StowerMacApp.swift"]
        main["@main StowerMacApp\nWindowGroup { StowerRootView() }"]
    end

    subgraph views["StowerMacUI · Views/StowerRootView.swift"]
        rootInit["StowerRootView.init()\nbuilds StowerMessagesComposition + StowerStartupModel + StowerBoardViewModel"]
        body["body → screen\nswitch model.state → child view"]
        task[".task { model.start() }"]
        disappear[".onDisappear { model.cancel() }"]
    end

    subgraph model["StowerMacUI · Startup/StowerStartupModel.swift  (@MainActor @Observable)"]
        start["start() / checkAgain()"]
        begin["beginRun()\ncancel in-flight · bump generation · spawn Task"]
        run["runStartup(generation:)\nmin-display delay · async let"]
        loadRoute["loadAndRoute()"]
        route["route(failure)\ntyped failure → state"]
        commit["commit(state, generation)\ngeneration-guarded write → state"]
    end

    subgraph adapter["StowerMacUI · Startup/StowerMessagesStartupAdapter.swift  (one of four engine-coupled files)"]
        aAvail["modelAvailability()\nmapAvailability"]
        aLoad["loadDebtBoard()\ndiscards board · mapError → StowerStartupFailure"]
    end

    subgraph engine["StowerMessages · StowerDebtBoardProvider.swift  (actor)"]
        eAvail["modelAvailability()\n→ modelAvailabilityResolver()"]
        eLoad["loadDebtBoard(config, now)\nbounds gate → availability gate → resolve judge"]
        eRefresh["refreshJudgments(config, now)\nsingle-flight · background · ONLY model caller"]
        readers["sharedReader() / refreshedReader()\n→ readerFactory()"]
    end

    subgraph judging["StowerMessages · StowerDebtBoardProviderJudging.swift"]
        judged["judgedConversations()\ntrusted cache reads only — NO model"]
        refreshPass["runRefreshPass()\nclassify → judgeRecord → persist"]
    end

    subgraph deps["StowerMessages · facts · policies · model · cache"]
        reader["StowerChatDatabaseReader\nconversationStateRecords() · threadMessages()\n(copies chat.db, integrity check)"]
        policies["StowerNoReplyPolicy.neglected\nStowerGhostedPolicy.ghosted"]
        judge["StowerReplyExpectationJudge\n(FoundationModels, per-record timeout)"]
        cache[("StowerReplyVerdictCache\nreply-verdicts.sqlite")]
    end

    main --> rootInit --> body
    body --> task --> start
    body -.-> disappear
    start --> begin --> run
    run -->|"await provider.modelAvailability()"| aAvail
    run --> loadRoute -->|"try await provider.loadDebtBoard()"| aLoad
    loadRoute --> route --> commit
    run --> commit -->|"@Observable re-renders"| body

    aAvail -->|"await engine.modelAvailability()"| eAvail
    aLoad -->|"try await engine.loadDebtBoard()"| eLoad

    eLoad --> readers --> reader
    eLoad -->|"records"| judged
    judged -->|"trusted verdicts"| cache
    eLoad --> policies

    eRefresh --> readers
    eRefresh --> refreshPass
    refreshPass -->|"judge un-cached"| judge
    refreshPass -->|"upsert verdicts"| cache
    judged -. "load reads what refresh wrote" .-> cache
```

The load path (`loadDebtBoard` → `judgedConversations`) **never runs the model**;
it serves only conversations a trusted verdict is already cached for. The
background `refreshJudgments` → `runRefreshPass` is the **only** model caller and
the **only** cache writer. The two never call each other — they communicate
through `StowerReplyVerdictCache` and the returned `StowerRefreshSummary`. That is
what lets the load return at structural speed and never block on the model.

### State machine — how the UI moves and keeps running

```mermaid
stateDiagram-v2
    direction TB
    [*] --> checkingModel : .task → start()

    checkingModel --> modelUnavailable : availability unavailable
    checkingModel --> needsLicense : available, no stored license
    checkingModel --> checkingMessages : available + license stored

    needsLicense --> checkingLicense : Activate (submit key)
    checkingLicense --> checkingMessages : activate succeeds
    checkingLicense --> needsLicense : invalid / couldNotReach

    checkingMessages --> connectedPreparingBoard : loadDebtBoard succeeds
    checkingMessages --> needsFullDiskAccess : FDA missing (first time)
    checkingMessages --> needsFullDiskAccessStillMissing : FDA missing after Check Again
    checkingMessages --> modelUnavailable : throws languageModelUnavailable
    checkingMessages --> failed : other typed failure

    modelUnavailable --> checkingModel : Check Again
    needsFullDiskAccess --> checkingModel : Check Again
    needsFullDiskAccessStillMissing --> checkingModel : Check Again
    failed --> checkingModel : Retry

    connectedPreparingBoard --> board : StowerRootView renders StowerBoardView

    note right of board
      Board lifecycle lives in the child StowerBoardViewModel,
      NOT in StowerStartupState (no .loadingJudgments / .ready /
      .allCaughtUp cases). Its own phase enum runs:
      preparing → rows / caughtUp / error, plus refresh.
      · clear preparing when judged + failed == total
      · reload board when changedChatIDs non-empty
      A board StowerStartupFailure → StowerStartupModel
      .handleBoardFailure → back into onboarding above.
    end note
```

The **license gate** sits between model-availability and the board load: once the
model is available, `runStartup` does a pure-local `licenseGate.hasStoredLicense()`
read (no network, no spinner). A stored license routes straight to
`checkingMessages`; otherwise the entry screen (`needsLicense`) is shown, and only a
user-submitted Activate runs `checkingLicense` (the `licenseGate.activate(key:)`
round-trip — the as-built gate is `StowerLemonSqueezyLicenseGate`), which on success
joins the same `continueAfterLicense` tail. The launch path never calls `/activate`.

Every transition runs under a **generation token**: `beginRun()` bumps a counter,
and `commit` writes `state` only if the completing run is still the current
generation — so an overlapping Check Again can never let a stale load overwrite a
newer run, and a `CancellationError` (superseded run, or `onDisappear → cancel()`)
routes to nothing, never to `.failed`. The view re-renders because
`StowerStartupModel` is `@Observable` and `body` reads `model.state`.

**How it "keeps running":** the startup flow is a one-shot that hands off at
`connectedPreparingBoard`, where `StowerRootView` renders `StowerBoardView` backed
by a child `StowerBoardViewModel`. `StowerStartupState` still has no board-era
cases — the board's richer lifecycle (preparing → rows / caught-up / error, plus
the background `refreshJudgments` loop that backfills verdicts and drives the
spinner/reload signals off `StowerRefreshSummary`) lives in the view-model's own
phase enum, not the startup enum. A board load that surfaces a
`StowerStartupFailure` (e.g. a mid-session FDA loss) re-enters onboarding via
`StowerStartupModel.handleBoardFailure`, so failure routing stays unified.

## System flow — ingest, query, and the relationship-debt engine

```mermaid
flowchart TB
    user["User query (text)"]

    subgraph adapters["Source adapters — depend on StowerCore, never each other"]
        direction TB
        photokit[("PhotoKit + FastVLM captions")]
        chatdb[("chat.db snapshot — read-only copy, PRAGMA quick_check")]
        photos["StowerPhotos"]
        messages["StowerMessages\n(StowerChatDatabaseReader)"]
        photokit --> photos
        chatdb --> messages
    end

    subgraph core["StowerCore — source-agnostic"]
        direction TB
        items["StowerIndexedItem values\nid = source:native-id"]
        index[["StowerIndex (actor, FTS5 DB)"]]
        replace["replaceAll: DELETE all → insert new set → FTS rebuild\n(one transaction, rebuild-only)"]
        search["search(query, limit)\nFTS5Pattern(matchingAllTokensIn:)"]
        rank["ORDER BY bm25(1.0, 0.25) ASC, timestamp DESC"]
        results["[StowerSearchResult]\n(item + marked snippet + score)"]
        grouped["groupedByGroupID\n(bucket by thread/album, keep rank)"]
        items --> replace --> index
        index --> search --> rank --> results --> grouped
    end

    photos --> items
    messages --> items
    user --> search
    grouped --> out1["Ranked, grouped matches → UI / summary"]

    subgraph debt["Relationship-debt engine — StowerMessages, FM-only, judged-only, NO index tables"]
        direction TB
        facts["conversationStates(windowDays:now:)"]
        ingest["ingestWindow → [StowerMessageItem] (incl. isOneToOne)"]
        activity["snapshot.activityRows → [StowerSourceActivityRow]\n(true last act, any content type)"]
        reacts["snapshot.reactionRows → [StowerSourceReactionRow] (w/ chatID)"]
        extract["StowerConversationStateExtractor (pure):\nlastActor · lastMessageKind · recentExchangeCount · reactedToLastMessage"]
        states["[StowerConversationState]\nneutral per-1:1 facts"]
        judge["refreshJudgments → FoundationModels judge\n(on-device, per-record timeout)"]
        cache[("StowerReplyVerdictCache\nreply-verdicts.sqlite — disposable")]
        neglected["StowerNoReplyPolicy.neglected:\n1:1 → mutuality → counterpart-last → not tapped back → ≥ threshold → should-respond verdict"]
        ghosted["StowerGhostedPolicy.ghosted:\n1:1 → mutuality → you-last → not tapped back → ≥ threshold → should-respond + confidence gate"]
        board["StowerDebtBoard\n(Neglected + Ghosted [StowerDebtItem])"]
        facts --> ingest
        facts --> activity
        facts --> reacts
        ingest --> extract
        activity --> extract
        reacts --> extract
        extract --> states --> judge --> cache
        cache --> neglected --> board
        cache --> ghosted --> board
    end

    chatdb -. "same read-only snapshot, two more read paths" .-> activity
    chatdb -. "same read-only snapshot, two more read paths" .-> reacts
    messages --> facts
```

The relationship-debt engine is **FoundationModels-only** and **judged-only**: a
conversation reaches the Neglected or Ghosted list only once the on-device model
has judged it and a trusted verdict is cached — unjudged conversations stay
invisible, and there is **no heuristic fallback**. On a Mac that can't run the
model the engine throws `languageModelUnavailable(reason)` (checked at startup via
`modelAvailability()`, before `loadDebtBoard` opens `chat.db`); the app routes to
an onboarding or unsupported screen rather than degrading to a heuristic board.
`loadDebtBoard` returns at structural speed from the cache and never runs the
model; `refreshJudgments` is the background pass that judges and backfills the
cache, reporting `judged`/`failed`/`total` and which chats changed.

## The tables (condensed)

There is **no database literally named "index."** The persistent search database
is the one the `StowerIndex` actor manages (caller-supplied file path; in-memory
in tests) and it holds the three tables below. The `chat.db` **snapshot** is a
throwaway temp copy of Apple's data. `llm_trace` is design-only (not built). The
relationship-debt engine writes no index tables; its only state is the disposable
`StowerReplyVerdictCache` (`reply-verdicts.sqlite`), which holds nothing but input
hashes and model verdicts and can be deleted at any time.

Each table's first row is a **LIFECYCLE** marker:
- `PERSISTENT_REBUILDABLE` — survives across runs; erased + rebuilt from sources on a `schema_version` bump.
- `TEMPORARY` — ephemeral file; deleted on release, swept after 1 day.
- `NOT_BUILT` — design anchor only.

```mermaid
erDiagram
    meta {
        LIFECYCLE _ "PERSISTENT_REBUILDABLE (StowerIndex DB)"
        text key   PK "schema_version"
        text value
    }
    item {
        LIFECYCLE _ "PERSISTENT_REBUILDABLE (StowerIndex DB)"
        text   id          PK "source:native-id"
        text   source
        text   text           "FTS weight 1.0"
        double timestamp      "tiebreak DESC"
        text   deep_link
        text   group_id       "grouping key"
        text   group_title    "FTS weight 0.25"
        text   metadata       "JSON"
    }
    item_fts {
        LIFECYCLE _ "PERSISTENT_REBUILDABLE (StowerIndex DB)"
        text text
        text group_title
    }
    snapshot_chat_db {
        LIFECYCLE _ "TEMPORARY — stower-msg-UUID/chat.db, deleted on release"
        note _ "read-only copy of Apple's chat.db (message/chat/handle/joins)"
    }
    item ||--|| item_fts : "external-content, bm25(1.0, 0.25)"
    snapshot_chat_db ..> item : "read by adapters → derived into"
```

> `meta` / `item` / `item_fts` are the **only persistent tables Stower owns**.
> `snapshot_chat_db` is Apple's data, temporary and read-only — its full columns
> (`message` / `chat` / `handle` / join tables) and the design-only `llm_trace`
> are in [`Docs/DataModel.md`](Docs/DataModel.md).

## The one-directional dependency rule

```mermaid
flowchart LR
    SP["StowerPhotos"] --> SC["StowerCore"]
    SM["StowerMessages"] --> SC
    SP -. "never imports" .- SM
```

Arrows point **into** `StowerCore`. Nothing depends on the adapters, and the two
adapters never import each other — that's what keeps the future Photos-only iOS
app from ever linking the Messages code (`AGENTS.md` §Architecture rules).
