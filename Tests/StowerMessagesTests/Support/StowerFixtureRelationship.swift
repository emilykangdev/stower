import Foundation

// Relationship no-reply fixtures: chats exercising the tapback and chronology
// reads. Each counterpart handle is unmapped, so `counterpart` falls back to the
// raw identifier. Synthetic handles/guids only.
extension StowerFixtureDatabase {
    internal static func reactionScenarios() -> [FixtureMessage] {
        reactionClearingScenarios() + reactionContextScenarios()
    }

    /// (a) cleared by a tapback, (b) add-then-remove nets out, (e) prefixed target.
    private static func reactionClearingScenarios() -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(
            incoming("clears-incoming", "did you see this?", daysAgo: 10, handle: 6, chat: 5)
        )
        values.append(
            reaction("clears-react", target: "clears-incoming", daysAgo: 9, type: 2000, chat: 5)
        )
        values.append(outgoing("removed-outgoing", "hey", daysAgo: 11, chat: 6))
        values.append(incoming("removed-incoming", "ping", daysAgo: 10, handle: 7, chat: 6))
        values.append(
            reaction("removed-add", target: "removed-incoming", daysAgo: 9, type: 2000, chat: 6)
        )
        values.append(
            reaction("removed-del", target: "removed-incoming", daysAgo: 9, type: 3000, chat: 6)
        )
        values.append(outgoing("prefixed-out", "mutual", daysAgo: 11, chat: 9))
        values.append(
            incoming("prefixed-incoming", "look at this", daysAgo: 10, handle: 10, chat: 9)
        )
        values.append(
            reaction(
                "prefixed-react",
                target: "p:0/prefixed-incoming",
                daysAgo: 9,
                type: 2000,
                chat: 9
            )
        )
        return values
    }

    /// (c) a tapback on an older message does not clear a newer one, and (d) a
    /// reaction to an attachment-only inbound (dropped by ingestWindow) establishes
    /// mutuality via chat provenance with no outbound present.
    private static func reactionContextScenarios() -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(incoming("oldreact-old", "old question", daysAgo: 20, handle: 8, chat: 7))
        values.append(outgoing("oldreact-out", "yeah", daysAgo: 19, chat: 7))
        values.append(incoming("oldreact-new", "newer question", daysAgo: 5, handle: 8, chat: 7))
        values.append(
            reaction("oldreact-react", target: "oldreact-old", daysAgo: 18, type: 2000, chat: 7)
        )
        values.append(attachmentIncoming("attach-old", daysAgo: 20, handle: 9, chat: 8))
        values.append(attachmentIncoming("attach-new", daysAgo: 5, handle: 9, chat: 8))
        values.append(
            reaction("attach-react", target: "attach-old", daysAgo: 18, type: 2000, chat: 8)
        )
        return values
    }

    /// (f) outbound non-text last act, (g) inbound non-text last act, (h) a system
    /// row that must not flip the last actor, and a stale thread whose only
    /// reciprocity is outside the recency window.
    internal static func chronologyScenarios() -> [FixtureMessage] {
        var values: [FixtureMessage] = []
        values.append(incoming("fattach-in", "your turn", daysAgo: 10, handle: 11, chat: 10))
        values.append(attachmentOutgoing("fattach-out", daysAgo: 5, chat: 10))
        values.append(incoming("gphoto-text", "earlier text", daysAgo: 10, handle: 12, chat: 11))
        values.append(outgoing("gphoto-out", "reply", daysAgo: 9, chat: 11))
        values.append(attachmentIncoming("gphoto-photo", daysAgo: 5, handle: 12, chat: 11))
        values.append(outgoing("hsys-out", "yes", daysAgo: 11, chat: 12))
        values.append(incoming("hsys-text", "are we still on?", daysAgo: 10, handle: 13, chat: 12))
        values.append(system("hsys-system", daysAgo: 5, chat: 12))
        values.append(outgoing("stale-out", "long ago", daysAgo: 170, chat: 13))
        values.append(incoming("stale-in", "recent ping", daysAgo: 3, handle: 14, chat: 13))
        return values
    }

    private static func incoming(
        _ id: String,
        _ text: String,
        daysAgo: Int,
        handle: Int64,
        chat: Int64
    ) -> FixtureMessage {
        FixtureMessage(
            id: id,
            text: text,
            date: rawDate(daysAgo: daysAgo),
            handleID: handle,
            chatID: chat
        )
    }

    private static func outgoing(
        _ id: String,
        _ text: String,
        daysAgo: Int,
        chat: Int64
    ) -> FixtureMessage {
        FixtureMessage(
            id: id,
            text: text,
            date: rawDate(daysAgo: daysAgo),
            isFromMe: true,
            handleID: 0,
            chatID: chat
        )
    }

    private static func attachmentIncoming(
        _ id: String,
        daysAgo: Int,
        handle: Int64,
        chat: Int64
    ) -> FixtureMessage {
        FixtureMessage(
            id: id,
            date: rawDate(daysAgo: daysAgo),
            handleID: handle,
            hasAttachments: true,
            chatID: chat
        )
    }

    private static func attachmentOutgoing(
        _ id: String,
        daysAgo: Int,
        chat: Int64
    ) -> FixtureMessage {
        FixtureMessage(
            id: id,
            date: rawDate(daysAgo: daysAgo),
            isFromMe: true,
            handleID: 0,
            hasAttachments: true,
            chatID: chat
        )
    }

    private static func reaction(
        _ id: String,
        target: String,
        daysAgo: Int,
        type: Int64,
        chat: Int64
    ) -> FixtureMessage {
        FixtureMessage(
            id: id,
            date: rawDate(daysAgo: daysAgo),
            isFromMe: true,
            handleID: 0,
            associatedType: type,
            associatedGuid: target,
            chatID: chat
        )
    }

    private static func system(
        _ id: String,
        daysAgo: Int,
        chat: Int64
    ) -> FixtureMessage {
        FixtureMessage(
            id: id,
            text: "Renamed the conversation",
            date: rawDate(daysAgo: daysAgo),
            isFromMe: true,
            handleID: 0,
            itemType: 1,
            chatID: chat
        )
    }
}
