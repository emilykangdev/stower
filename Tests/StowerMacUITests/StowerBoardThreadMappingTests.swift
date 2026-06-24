import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The engine→`StowerThreadLine` mapping (I11): output order equals input order
/// (never re-sorted), the side comes from `isFromMe`, the most-recent line is
/// flagged, the non-text rule applies, and identity is the message GUID.
@Suite internal struct StowerBoardThreadMappingTests {
    private func message(
        id: String,
        isFromMe: Bool = false,
        kind: StowerConversationLastMessageKind = .text,
        text: String? = "hi"
    ) -> StowerThreadMessage {
        StowerThreadMessage(
            id: id,
            isFromMe: isFromMe,
            timestamp: Date(timeIntervalSince1970: 0),
            text: text,
            kind: kind
        )
    }

    @Test("output order equals input order, sides from isFromMe, last is emphasized")
    internal func preservesOrderSidesAndEmphasis() {
        let input = [
            message(id: "m1", isFromMe: false),
            message(id: "m2", isFromMe: true),
            message(id: "m3", isFromMe: false)
        ]
        let lines = StowerMessagesMapping.mapThread(input)

        #expect(lines.map(\.id) == ["m1", "m2", "m3"])
        #expect(lines.map(\.isFromMe) == [false, true, false])
        #expect(lines.map(\.isMostRecent) == [false, false, true])
    }

    @Test("a non-text line carries the per-kind placeholder, flagged")
    internal func nonTextLinePlaceholder() {
        let lines = StowerMessagesMapping.mapThread([
            message(id: "m1", kind: .attachment, text: nil)
        ])
        #expect(lines.first?.summary.label == "Sent an attachment")
        #expect(lines.first?.summary.isPlaceholder == true)
    }

    @Test("an empty thread maps to no lines")
    internal func emptyThread() {
        #expect(StowerMessagesMapping.mapThread([]).isEmpty)
    }

    @Test("a single line is flagged most-recent")
    internal func singleLineIsMostRecent() {
        let lines = StowerMessagesMapping.mapThread([message(id: "only", isFromMe: true)])
        #expect(lines.map(\.isMostRecent) == [true])
    }
}
