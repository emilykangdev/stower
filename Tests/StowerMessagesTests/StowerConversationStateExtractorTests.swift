import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerConversationStateExtractor")
internal struct StowerConversationStateExtractorTests {
    @Test("group chats never produce a state")
    internal func groupExcluded() {
        let group = chat("g", style: 43)
        let states = extract(activity: acts(activity("g1", daysAgo: 5, fromMe: false, chat: group)))
        #expect(states.isEmpty)
    }

    @Test("outbound attachment after inbound text ⇒ lastActor user")
    internal func outboundAttachmentFlipsLastActor() throws {
        let chat = chat("a")
        let states = extract(
            items: itemList(item("a1", "hi", chat: chat)),
            activity: acts(
                activity("a1", daysAgo: 10, fromMe: false, chat: chat),
                activity(
                    "a2",
                    daysAgo: 5,
                    fromMe: true,
                    chat: chat,
                    hasText: false,
                    hasAttachments: true
                )
            )
        )
        let state = try #require(states.first { $0.chatID == "a" })
        #expect(state.lastActor == .user)
        #expect(state.lastMessageKind == .attachment)
    }

    @Test("inbound attachment newer than inbound text ⇒ surfaced kind=attachment, text nil")
    internal func inboundAttachmentSurfaces() throws {
        let chat = chat("b")
        let states = extract(
            items: itemList(
                item("b1", "earlier", chat: chat),
                item("b2", "reply", chat: chat, fromMe: true)
            ),
            activity: acts(
                activity("b1", daysAgo: 10, fromMe: false, chat: chat),
                activity("b2", daysAgo: 9, fromMe: true, chat: chat),
                activity(
                    "b3",
                    daysAgo: 5,
                    fromMe: false,
                    chat: chat,
                    hasText: false,
                    hasAttachments: true
                )
            )
        )
        let state = try #require(states.first { $0.chatID == "b" })
        #expect(state.lastActor == .counterpart)
        #expect(state.lastMessageKind == .attachment)
        #expect(state.lastMessageText == nil)
    }

    @Test("a link last act is labelled link with its body text")
    internal func linkLastActLabelled() throws {
        let chat = chat("k")
        let url = StowerMessageMapper.urlPreviewBalloonBundleID
        let states = extract(
            items: itemList(item("k1", "https://example.com", chat: chat)),
            activity: acts(
                activity("k0", daysAgo: 9, fromMe: true, chat: chat),
                activity("k1", daysAgo: 5, fromMe: false, chat: chat, balloon: url)
            )
        )
        let state = try #require(states.first { $0.chatID == "k" })
        #expect(state.lastMessageKind == .link)
        #expect(state.lastMessageText == "https://example.com")
    }

    @Test("reaction to a non-indexable inbound establishes engagement via chat provenance")
    internal func reactionEstablishesEngagement() throws {
        let chat = chat("d")
        let states = extract(
            activity: acts(
                activity(
                    "d1",
                    daysAgo: 20,
                    fromMe: false,
                    chat: chat,
                    hasText: false,
                    hasAttachments: true
                ),
                activity(
                    "d2",
                    daysAgo: 5,
                    fromMe: false,
                    chat: chat,
                    hasText: false,
                    hasAttachments: true
                )
            ),
            reactions: reacts(reaction(1, target: "d1", daysAgo: 18, type: 2000, chat: chat))
        )
        let state = try #require(states.first { $0.chatID == "d" })
        #expect(state.recentExchangeCount >= 1)
        #expect(state.lastActor == .counterpart)
        #expect(state.userReactedToLastMessage == false)
    }

    @Test("a tapback on the counterpart's last message clears it")
    internal func tapbackClears() throws {
        let chat = chat("c")
        let states = extract(
            items: itemList(item("c1", "did you see this?", chat: chat)),
            activity: acts(
                activity("c0", daysAgo: 11, fromMe: true, chat: chat),
                activity("c1", daysAgo: 10, fromMe: false, chat: chat)
            ),
            reactions: reacts(reaction(1, target: "c1", daysAgo: 9, type: 2000, chat: chat))
        )
        let state = try #require(states.first { $0.chatID == "c" })
        #expect(state.userReactedToLastMessage)
    }

    @Test("add-then-remove at equal dates nets out by ROWID ⇒ not cleared")
    internal func removedReactionNetsOut() throws {
        let chat = chat("r")
        let states = extract(
            activity: acts(
                activity("r0", daysAgo: 11, fromMe: true, chat: chat),
                activity("r1", daysAgo: 10, fromMe: false, chat: chat)
            ),
            reactions: reacts(
                reaction(1, target: "r1", daysAgo: 9, type: 2000, chat: chat),
                reaction(2, target: "r1", daysAgo: 9, type: 3000, chat: chat)
            )
        )
        let state = try #require(states.first { $0.chatID == "r" })
        #expect(state.userReactedToLastMessage == false)
    }

    @Test("ROWID tie-break: a later add wins over an equal-date remove ⇒ cleared")
    internal func laterAddWinsByRowID() throws {
        let chat = chat("r2")
        let states = extract(
            activity: acts(activity("x1", daysAgo: 10, fromMe: false, chat: chat)),
            reactions: reacts(
                reaction(1, target: "x1", daysAgo: 9, type: 3000, chat: chat),
                reaction(2, target: "x1", daysAgo: 9, type: 2000, chat: chat)
            )
        )
        let state = try #require(states.first { $0.chatID == "r2" })
        #expect(state.userReactedToLastMessage)
    }

    @Test("a tapback on an older message does not clear a newer one")
    internal func oldReactionDoesNotClearNewer() throws {
        let chat = chat("o")
        let states = extract(
            items: itemList(item("o1", "old", chat: chat), item("o2", "newer", chat: chat)),
            activity: acts(
                activity("o1", daysAgo: 20, fromMe: false, chat: chat),
                activity("o0", daysAgo: 19, fromMe: true, chat: chat),
                activity("o2", daysAgo: 5, fromMe: false, chat: chat)
            ),
            reactions: reacts(reaction(1, target: "o1", daysAgo: 18, type: 2000, chat: chat))
        )
        let state = try #require(states.first { $0.chatID == "o" })
        #expect(state.userReactedToLastMessage == false)
    }

    @Test("removing one reacted part does not un-react a multipart message")
    internal func multipartReactionPartsNetIndependently() throws {
        let chat = chat("m")
        let states = extract(
            activity: acts(activity("msg", daysAgo: 10, fromMe: false, chat: chat)),
            reactions: reacts(
                reaction(1, target: "p:0/msg", daysAgo: 9, type: 2000, chat: chat),
                reaction(2, target: "p:1/msg", daysAgo: 8, type: 2000, chat: chat),
                reaction(3, target: "p:1/msg", daysAgo: 7, type: 3000, chat: chat)
            )
        )
        let state = try #require(states.first { $0.chatID == "m" })
        #expect(state.userReactedToLastMessage)
    }

    @Test("a part's add and remove net out across encoding wrappers (bare add, p:0 remove)")
    internal func reactionNetsAcrossEncodings() throws {
        let chat = chat("e")
        let states = extract(
            activity: acts(activity("e1", daysAgo: 10, fromMe: false, chat: chat)),
            reactions: reacts(
                reaction(1, target: "e1", daysAgo: 9, type: 2000, chat: chat),
                reaction(2, target: "p:0/e1", daysAgo: 8, type: 3000, chat: chat)
            )
        )
        let state = try #require(states.first { $0.chatID == "e" })
        #expect(state.userReactedToLastMessage == false)
    }

    @Test("a prefixed target GUID clears only after normalization")
    internal func prefixedTargetClears() throws {
        let chat = chat("p")
        let states = extract(
            activity: acts(activity("p1", daysAgo: 10, fromMe: false, chat: chat)),
            reactions: reacts(reaction(1, target: "p:0/p1", daysAgo: 9, type: 2000, chat: chat))
        )
        let state = try #require(states.first { $0.chatID == "p" })
        #expect(state.userReactedToLastMessage)
    }

    @Test("equal-timestamp inbound+outbound ⇒ the later row (outbound) acted last")
    internal func equalTimestampOutboundWins() throws {
        let chat = chat("t")
        let states = extract(
            activity: acts(
                activity("t1", daysAgo: 2, fromMe: false, chat: chat),
                activity("t2", daysAgo: 2, fromMe: true, chat: chat)
            )
        )
        let state = try #require(states.first { $0.chatID == "t" })
        #expect(state.lastActor == .user)
    }

    @Test("recent reciprocity is counted; a stale lone outbound is not")
    internal func recencyGate() throws {
        let recent = chat("recent")
        let stale = chat("stale")
        let states = extract(
            activity: acts(
                activity("recent-in", daysAgo: 10, fromMe: false, chat: recent),
                activity("recent-out", daysAgo: 8, fromMe: true, chat: recent),
                activity("recent-in2", daysAgo: 5, fromMe: false, chat: recent),
                activity("stale-out", daysAgo: 170, fromMe: true, chat: stale),
                activity("stale-in", daysAgo: 3, fromMe: false, chat: stale)
            )
        )
        let recentState = try #require(states.first { $0.chatID == "recent" })
        let staleState = try #require(states.first { $0.chatID == "stale" })
        #expect(recentState.recentExchangeCount >= 1)
        #expect(staleState.recentExchangeCount == 0)
    }

    @Test("normalizeAssociatedGUID strips part-reference prefixes")
    internal func normalizeStripsPrefixes() {
        #expect(StowerMessageQuery.normalizeAssociatedGUID("p:0/ABC") == "ABC")
        #expect(StowerMessageQuery.normalizeAssociatedGUID("p:12/X-Y-Z") == "X-Y-Z")
        #expect(StowerMessageQuery.normalizeAssociatedGUID("bp:ABC") == "ABC")
        #expect(StowerMessageQuery.normalizeAssociatedGUID("ABC") == "ABC")
    }

    @Test("associatedGUIDPart reads the part index, defaulting bare/bp to part 0")
    internal func partIndexParsing() {
        #expect(StowerMessageQuery.associatedGUIDPart("p:0/ABC") == "0")
        #expect(StowerMessageQuery.associatedGUIDPart("p:12/ABC") == "12")
        #expect(StowerMessageQuery.associatedGUIDPart("bp:ABC") == "0")
        #expect(StowerMessageQuery.associatedGUIDPart("ABC") == "0")
    }
}

// MARK: - Synthetic builders

extension StowerConversationStateExtractorTests {
    private var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    fileprivate func extract(
        items: [StowerMessageItem] = [],
        activity: [StowerSourceActivityRow] = [],
        reactions: [StowerSourceReactionRow] = []
    ) -> [StowerConversationState] {
        StowerConversationStateExtractor.states(
            items: items,
            activity: activity,
            reactions: reactions,
            contacts: StowerContactsResolver(),
            now: now
        )
    }

    fileprivate func acts(_ rows: StowerSourceActivityRow...) -> [StowerSourceActivityRow] { rows }
    fileprivate func reacts(_ rows: StowerSourceReactionRow...) -> [StowerSourceReactionRow] {
        rows
    }
    fileprivate func itemList(_ rows: StowerMessageItem...) -> [StowerMessageItem] { rows }

    private func raw(_ daysAgo: Double) -> Int64 {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    fileprivate func chat(_ id: String, style: Int64 = 45) -> StowerSourceChatRow {
        StowerSourceChatRow(
            rowID: 1,
            guid: id,
            identifier: "+1555000\(id)",
            displayName: nil,
            style: style
        )
    }

    fileprivate func activity(
        _ guid: String,
        daysAgo: Double,
        fromMe: Bool,
        chat: StowerSourceChatRow,
        hasText: Bool = true,
        hasAttachments: Bool = false,
        balloon: String? = nil
    ) -> StowerSourceActivityRow {
        StowerSourceActivityRow(
            guid: guid,
            rawDate: raw(daysAgo),
            isFromMe: fromMe,
            hasAttachments: hasAttachments,
            balloonBundleID: balloon,
            hasText: hasText,
            chat: chat
        )
    }

    fileprivate func reaction(
        _ rowID: Int64,
        target: String,
        daysAgo: Double,
        type: Int64,
        chat: StowerSourceChatRow
    ) -> StowerSourceReactionRow {
        StowerSourceReactionRow(
            reactionRowID: rowID,
            associatedMessageGuid: target,
            associatedMessageType: type,
            rawDate: raw(daysAgo),
            isFromMe: true,
            chat: chat
        )
    }

    fileprivate func item(
        _ guid: String,
        _ text: String,
        chat: StowerSourceChatRow,
        fromMe: Bool = false
    ) -> StowerMessageItem {
        StowerMessageItem(
            id: guid,
            text: text,
            timestamp: now,
            deepLink: nil,
            groupID: chat.groupID,
            groupTitle: chat.identifier,
            isFromMe: fromMe,
            sender: "x",
            isOneToOne: chat.isOneToOne
        )
    }
}
