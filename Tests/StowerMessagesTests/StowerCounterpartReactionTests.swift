import Foundation
import Testing

@testable import StowerMessages

/// Facts-level coverage of the counterpart-reaction netting that backs the
/// Ghosted gate (T1): a counterpart tapback on the user's last message sets
/// `counterpartReactedToLastMessage`, while the user's own tapback does not.
@Suite("StowerConversationState counterpart reactions")
internal struct StowerCounterpartReactionTests {
    @Test("a counterpart tapback on the user's last message sets the flag (T1)")
    internal func counterpartTapbackSetsFlag() throws {
        let chat = chat("c")
        let states = extract(
            activity: [
                activity("c1", daysAgo: 10, fromMe: false, chat: chat),
                activity("c2", daysAgo: 5, fromMe: true, chat: chat)
            ],
            reactions: [reaction(1, target: "c2", daysAgo: 4, chat: chat, fromMe: false)]
        )
        let state = try #require(states.first { $0.chatID == "c" })
        #expect(state.lastActor == .user)
        #expect(state.counterpartReactedToLastMessage)
        #expect(!state.userReactedToLastMessage)
    }

    @Test("a user tapback does not set the counterpart-reacted flag")
    internal func userTapbackLeavesCounterpartFlagFalse() throws {
        let chat = chat("d")
        let states = extract(
            activity: [activity("d1", daysAgo: 10, fromMe: false, chat: chat)],
            reactions: [reaction(1, target: "d1", daysAgo: 9, chat: chat, fromMe: true)]
        )
        let state = try #require(states.first { $0.chatID == "d" })
        #expect(state.userReactedToLastMessage)
        #expect(!state.counterpartReactedToLastMessage)
    }
}

// MARK: - Synthetic builders

extension StowerCounterpartReactionTests {
    private var now: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }

    private func raw(_ daysAgo: Double) -> Int64 {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    fileprivate func extract(
        activity: [StowerSourceActivityRow],
        reactions: [StowerSourceReactionRow]
    ) -> [StowerConversationState] {
        StowerConversationStateExtractor.states(
            items: [],
            activity: activity,
            reactions: reactions,
            contacts: StowerContactsResolver(),
            now: now
        )
    }

    fileprivate func chat(_ id: String) -> StowerSourceChatRow {
        StowerSourceChatRow(
            rowID: 1,
            guid: id,
            identifier: "+1555000\(id)",
            displayName: nil,
            style: 45
        )
    }

    fileprivate func activity(
        _ guid: String,
        daysAgo: Double,
        fromMe: Bool,
        chat: StowerSourceChatRow
    ) -> StowerSourceActivityRow {
        StowerSourceActivityRow(
            guid: guid,
            rawDate: raw(daysAgo),
            isFromMe: fromMe,
            hasAttachments: false,
            balloonBundleID: nil,
            hasText: true,
            chat: chat
        )
    }

    fileprivate func reaction(
        _ rowID: Int64,
        target: String,
        daysAgo: Double,
        chat: StowerSourceChatRow,
        fromMe: Bool
    ) -> StowerSourceReactionRow {
        StowerSourceReactionRow(
            reactionRowID: rowID,
            associatedMessageGuid: target,
            associatedMessageType: 2000,
            rawDate: raw(daysAgo),
            isFromMe: fromMe,
            chat: chat
        )
    }
}
