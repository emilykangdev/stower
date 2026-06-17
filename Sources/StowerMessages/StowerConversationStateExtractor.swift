import Foundation

/// Pure derivation of per-1:1 conversation facts from the three reads.
///
/// Given the indexable items (for text/title), the full chronology (for the
/// true last act and reciprocity), and the user's netted tapbacks (for
/// engagement and last-message clearing), it emits one `StowerConversationState`
/// per one-to-one chat. No I/O; deterministic given its inputs.
internal enum StowerConversationStateExtractor {
    /// Recency sub-window (days) for counting reciprocal exchanges.
    ///
    /// A relationship that last exchanged outside this window contributes no
    /// recent reciprocity, so the no-reply policy's mutuality gate filters stale
    /// transactional threads. Two-way door; widen if real boards exclude live
    /// relationships.
    internal static let reciprocityWindowDays = 60

    internal static func states(
        items: [StowerMessageItem],
        activity: [StowerSourceActivityRow],
        reactions: [StowerSourceReactionRow],
        contacts: StowerContactsResolver,
        now: Date
    ) -> [StowerConversationState] {
        records(
            items: items,
            activity: activity,
            reactions: reactions,
            contacts: contacts,
            now: now
        ).map(\.state)
    }

    /// Emits one record per 1:1 chat, each pairing the facts with the last act's
    /// GUID for the verdict cache (the GUID never reaches the public init, M2).
    internal static func records(
        items: [StowerMessageItem],
        activity: [StowerSourceActivityRow],
        reactions: [StowerSourceReactionRow],
        contacts: StowerContactsResolver,
        now: Date
    ) -> [StowerConversationStateRecord] {
        let itemsByGUID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let titleByChat = Dictionary(
            items.map { ($0.groupID, $0.groupTitle) },
            uniquingKeysWith: { first, _ in first }
        )
        let userNet = netReactions(reactions.filter(\.isFromMe))
        let counterpartNet = netReactions(reactions.filter { !$0.isFromMe })
        let inputs = Inputs(
            itemsByGUID: itemsByGUID,
            titleByChat: titleByChat,
            userActiveTargets: activeTargetsByChat(userNet),
            counterpartActiveTargets: activeTargetsByChat(counterpartNet),
            reactionActs: reactionActsByChat(userNet),
            contacts: contacts,
            cutoff: now.addingTimeInterval(-Double(reciprocityWindowDays) * 86_400)
        )
        let grouped = Dictionary(grouping: activity, by: { $0.chat.groupID })
        return grouped.compactMap { chatID, rows in
            record(chatID: chatID, rows: rows, inputs: inputs)
        }
        .sorted { $0.state.chatID < $1.state.chatID }
    }

    private static func record(
        chatID: String,
        rows: [StowerSourceActivityRow],
        inputs: Inputs
    ) -> StowerConversationStateRecord? {
        guard let chat = rows.first?.chat, chat.isOneToOne, let last = rows.last,
            let lastTimestamp = StowerMessageDate.date(from: last.rawDate)
        else {
            return nil
        }
        let counterpartHandle = chat.identifier
        let counterpart = inputs.contacts.displayName(for: counterpartHandle)
        let kind = classifyKind(last)
        let state = StowerConversationState(
            chatID: chatID,
            chatTitle: inputs.titleByChat[chatID] ?? counterpart,
            counterpart: counterpart,
            counterpartHandle: counterpartHandle,
            isOneToOne: true,
            lastActor: last.isFromMe ? .user : .counterpart,
            lastInboundAt: lastDate(rows, isFromMe: false),
            lastOutboundAt: lastDate(rows, isFromMe: true),
            lastMessageKind: kind,
            lastMessageText: lastMessageText(item: inputs.itemsByGUID[last.guid], kind: kind),
            lastMessageTimestamp: lastTimestamp,
            recentExchangeCount: recentExchangeCount(
                rows: rows,
                reactionActs: inputs.reactionActs[chatID] ?? [],
                cutoff: inputs.cutoff
            ),
            userReactedToLastMessage: (inputs.userActiveTargets[chatID] ?? []).contains(last.guid),
            counterpartReactedToLastMessage: (inputs.counterpartActiveTargets[chatID] ?? [])
                .contains(last.guid),
            deepLink: chat.deepLink
        )
        return StowerConversationStateRecord(state: state, lastMessageGUID: last.guid)
    }

    /// Shared lookups threaded through the per-chat fold.
    private struct Inputs {
        let itemsByGUID: [String: StowerMessageItem]
        let titleByChat: [String: String]
        let userActiveTargets: [String: Set<String>]
        let counterpartActiveTargets: [String: Set<String>]
        let reactionActs: [String: [Date]]
        let contacts: StowerContactsResolver
        let cutoff: Date
    }

    /// Coarsely labels a chronology row from the message columns alone.
    ///
    /// A non-URL balloon is `app` even when it carries body text, mirroring the
    /// indexable contract (only `NULL`/URL-balloon rows hold recall-worthy text).
    private static func classifyKind(
        _ row: StowerSourceActivityRow
    ) -> StowerConversationLastMessageKind {
        classifyKind(
            balloonBundleID: row.balloonBundleID,
            hasText: row.hasText,
            hasAttachments: row.hasAttachments
        )
    }

    /// Coarsely labels a message from its raw columns alone.
    ///
    /// Shared by the chronology fold and the thread-read so both classify a row
    /// identically (M7) — a non-URL balloon is `app` even when it carries body
    /// text, mirroring the indexable contract.
    internal static func classifyKind(
        balloonBundleID: String?,
        hasText: Bool,
        hasAttachments: Bool
    ) -> StowerConversationLastMessageKind {
        if balloonBundleID == StowerMessageMapper.urlPreviewBalloonBundleID {
            return .link
        }
        if balloonBundleID != nil {
            return .app
        }
        if hasText {
            return .text
        }
        if hasAttachments {
            return .attachment
        }
        return .other
    }

    private static func lastMessageText(
        item: StowerMessageItem?,
        kind: StowerConversationLastMessageKind
    ) -> String? {
        guard kind == .text || kind == .link else {
            return nil
        }
        return item?.text
    }

    private static func lastDate(
        _ rows: [StowerSourceActivityRow],
        isFromMe: Bool
    ) -> Date? {
        for row in rows.reversed() where row.isFromMe == isFromMe {
            if let date = StowerMessageDate.date(from: row.rawDate) {
                return date
            }
        }
        return nil
    }

    /// Counts how many times the conversation changed hands within the recency
    /// sub-window, treating the user's own tapbacks as user acts.
    private static func recentExchangeCount(
        rows: [StowerSourceActivityRow],
        reactionActs: [Date],
        cutoff: Date
    ) -> Int {
        var acts: [(date: Date, isUser: Bool)] = []
        for row in rows {
            if let date = StowerMessageDate.date(from: row.rawDate), date >= cutoff {
                acts.append((date, row.isFromMe))
            }
        }
        for date in reactionActs where date >= cutoff {
            acts.append((date, true))
        }
        acts.sort { $0.date < $1.date }
        var count = 0
        var previous: Bool?
        for act in acts {
            if let previous, previous != act.isUser {
                count += 1
            }
            previous = act.isUser
        }
        return count
    }

    /// Keeps the latest add/remove event per `(chat, part, bare guid)`.
    ///
    /// A removed tapback nets out; deterministic on equal dates via the reaction
    /// ROWID. The key keeps the part index but canonicalizes the wrapper to the
    /// bare guid, so two things hold at once: distinct parts of one multipart
    /// message (photo + caption) net independently — removing one part must not
    /// mark the whole message un-reacted while another part stays active — AND a
    /// part's add/remove still net when stored under different encodings (an old
    /// bare add vs a new `p:0/` remove across an OS migration).
    private static func netReactions(
        _ reactions: [StowerSourceReactionRow]
    ) -> [ChatTargetKey: ReactionEvent] {
        let ordered = reactions.sorted { lhs, rhs in
            lhs.rawDate != rhs.rawDate
                ? lhs.rawDate < rhs.rawDate
                : lhs.reactionRowID < rhs.reactionRowID
        }
        var net: [ChatTargetKey: ReactionEvent] = [:]
        for reaction in ordered {
            guard let target = reaction.associatedMessageGuid,
                let date = StowerMessageDate.date(from: reaction.rawDate)
            else {
                continue
            }
            let key = ChatTargetKey(
                chatID: reaction.chat.groupID,
                part: StowerMessageQuery.associatedGUIDPart(target),
                guid: StowerMessageQuery.normalizeAssociatedGUID(target)
            )
            net[key] = ReactionEvent(isActive: reaction.associatedMessageType < 3000, date: date)
        }
        return net
    }

    /// Bare message GUIDs with at least one net-active reacted part, per chat.
    private static func activeTargetsByChat(
        _ net: [ChatTargetKey: ReactionEvent]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (key, event) in net where event.isActive {
            result[key.chatID, default: []].insert(key.guid)
        }
        return result
    }

    /// Dates of the user's still-active tapbacks per chat, fed to reciprocity.
    ///
    /// They count as user acts. A netted-out (added-then-removed) reaction is
    /// `isActive == false` and contributes nothing: an un-done tapback is not
    /// engagement.
    private static func reactionActsByChat(
        _ net: [ChatTargetKey: ReactionEvent]
    ) -> [String: [Date]] {
        var result: [String: [Date]] = [:]
        for (key, event) in net where event.isActive {
            result[key.chatID, default: []].append(event.date)
        }
        return result
    }

    private struct ChatTargetKey: Hashable {
        let chatID: String
        let part: String
        let guid: String
    }

    private struct ReactionEvent {
        let isActive: Bool
        let date: Date
    }
}
