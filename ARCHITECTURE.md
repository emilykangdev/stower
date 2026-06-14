# Stower — Architecture at a glance

Two diagrams: **how a query flows through the system today**, and **the tables**.
For the full per-table column detail and ownership/status notes, see
[`Docs/DataModel.md`](Docs/DataModel.md); this file is the bird's-eye view.

## System flow — ingest, query, and the no-reply engine

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

    subgraph debt["Relationship no-reply engine — StowerMessages, NO tables, NOT via the index"]
        direction TB
        facts["conversationStates(windowDays:now:)"]
        ingest["ingestWindow → [StowerMessageItem] (incl. isOneToOne)"]
        activity["snapshot.activityRows → [StowerSourceActivityRow]\n(true last act, any content type)"]
        reacts["snapshot.reactionRows → [StowerSourceReactionRow] (w/ chatID)"]
        extract["StowerConversationStateExtractor (pure):\nlastActor · lastMessageKind · recentExchangeCount · userReactedToLastMessage"]
        states["[StowerConversationState]\nneutral per-1:1 facts"]
        policy["noReplyCandidates(...) = StowerNoReplyPolicy:\n1:1 → recency mutuality → counterpart-last → not tapback-cleared → ≥ threshold"]
        cands["[StowerNoReplyCandidate]\nranked most-recently-unanswered first"]
        facts --> ingest
        facts --> activity
        facts --> reacts
        ingest --> extract
        activity --> extract
        reacts --> extract
        extract --> states --> policy --> cands
        states --> drift["future 'drift' policy / UI"]
    end

    chatdb -. "same read-only snapshot, two more read paths" .-> activity
    chatdb -. "same read-only snapshot, two more read paths" .-> reacts
    messages --> facts
```

## The tables (condensed)

There is **no database literally named "index."** The persistent search database
is the one the `StowerIndex` actor manages (caller-supplied file path; in-memory
in tests) and it holds the three tables below. The `chat.db` **snapshot** is a
throwaway temp copy of Apple's data. `llm_trace` is design-only (not built). The
no-reply engine stores nothing.

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
