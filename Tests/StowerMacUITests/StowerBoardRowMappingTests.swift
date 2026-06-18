import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The engine→`StowerBoardRow` mapping: deep-link enable rule (I3), binary-first
/// confidence (I5), kind mapping, age derivation (I12), and stable identity (I14).
///
/// Drives the shared engine-coupled `StowerMessagesMapping.mapRow` over synthetic
/// `StowerDebtItem`s (the test target depends on the engine).
@Suite internal struct StowerBoardRowMappingTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        chatID: String = "chat-1",
        counterpart: String = "Alex Rivera",
        kind: StowerConversationLastMessageKind = .text,
        text: String? = "hello",
        timestamp: Date = now,
        deepLink: URL? = URL(string: "sms:+14155550100"),
        confidence: Double = 0.8
    ) -> StowerDebtItem {
        StowerDebtItem(
            chatID: chatID,
            chatTitle: "Alex",
            counterpart: counterpart,
            counterpartHandle: "+14155550100",
            lastMessageKind: kind,
            lastMessageText: text,
            lastMessageTimestamp: timestamp,
            deepLink: deepLink,
            replyExpectationConfidence: confidence
        )
    }

    @Test("a deep link enables Open in Messages; its absence disables it (I3)")
    internal func deepLinkDrivesEnable() {
        let withLink = StowerMessagesMapping.mapRow(item(), now: Self.now)
        let withoutLink = StowerMessagesMapping.mapRow(item(deepLink: nil), now: Self.now)
        #expect(withLink.canOpenInMessages)
        #expect(withLink.deepLink == URL(string: "sms:+14155550100"))
        #expect(withoutLink.canOpenInMessages == false)
        #expect(withoutLink.deepLink == nil)
    }

    @Test("confidence never reaches the row: 0.51 and 0.99 map identically (I5)")
    internal func confidenceIsDropped() {
        let low = StowerMessagesMapping.mapRow(item(confidence: 0.51), now: Self.now)
        let high = StowerMessagesMapping.mapRow(item(confidence: 0.99), now: Self.now)
        #expect(low == high)
    }

    @Test("the row identity is the stable chatID, not the display name (I14)")
    internal func identityIsChatID() {
        let row = StowerMessagesMapping.mapRow(item(chatID: "chat-42"), now: Self.now)
        #expect(row.id == "chat-42")
        #expect(row.chatID == "chat-42")
        // Two rows differing only in counterpart text keep distinct ids by chatID.
        let zoeItemA = item(chatID: "a", counterpart: "Zoe")
        let zoeItemB = item(chatID: "b", counterpart: "Zoe")
        let rowA = StowerMessagesMapping.mapRow(zoeItemA, now: Self.now)
        let rowB = StowerMessagesMapping.mapRow(zoeItemB, now: Self.now)
        #expect(rowA.id != rowB.id)
    }

    @Test(
        "each engine kind maps to its app mirror and placeholder when text is absent",
        arguments: [
            (StowerConversationLastMessageKind.text, "Sent a message"),
            (.link, "Sent a link"),
            (.attachment, "Sent an attachment"),
            (.app, "Sent an app message"),
            (.other, "Sent a message")
        ]
    )
    internal func kindMapsAndDrivesPlaceholder(
        kind: StowerConversationLastMessageKind,
        expected: String
    ) {
        let row = StowerMessagesMapping.mapRow(item(kind: kind, text: nil), now: Self.now)
        #expect(row.summary.label == expected)
        #expect(row.summary.isPlaceholder)
    }

    @Test("age is whole days floored, and future skew clamps to zero (I12)")
    internal func ageDerivation() {
        let threeDaysAgo = Self.now.addingTimeInterval(-3.5 * 86_400)
        let aged = StowerMessagesMapping.mapRow(item(timestamp: threeDaysAgo), now: Self.now)
        #expect(aged.ageInDays == 3)

        let sameInstant = StowerMessagesMapping.mapRow(item(timestamp: Self.now), now: Self.now)
        #expect(sameInstant.ageInDays == 0)

        let future = Self.now.addingTimeInterval(86_400)
        let skewed = StowerMessagesMapping.mapRow(item(timestamp: future), now: Self.now)
        #expect(skewed.ageInDays == 0)
    }

    @Test("the monogram takes up to two initials, uppercased")
    internal func monogram() {
        #expect(StowerBoardRow.monogram(for: "alex rivera") == "AR")
        #expect(StowerBoardRow.monogram(for: "Madonna") == "M")
        #expect(StowerBoardRow.monogram(for: "+14155550100") == "1")
        #expect(StowerBoardRow.monogram(for: "   ") == "?")
    }
}
