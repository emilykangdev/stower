import Testing

@testable import StowerMacUI

/// The non-text rule (I1): real text renders verbatim and not-as-placeholder; a
/// `nil`/empty/whitespace-only act renders the per-kind placeholder, flagged so the
/// view shows it italic + angle-bracketed and never as the sender's literal words.
@Suite internal struct StowerLastMessageSummaryTests {
    @Test("non-empty text renders verbatim and is not a placeholder")
    internal func verbatimTextIsNotPlaceholder() {
        let summary = StowerLastMessageSummary.make(kind: .text, text: "see you at 6")
        #expect(summary.label == "see you at 6")
        #expect(summary.isPlaceholder == false)
    }

    @Test(
        "a nil last act yields the per-kind placeholder, flagged",
        arguments: [
            (StowerLastMessageKind.text, "Sent a message"),
            (.link, "Sent a link"),
            (.attachment, "Sent an attachment"),
            (.app, "Sent an app message"),
            (.other, "Sent a message")
        ]
    )
    internal func nilTextYieldsPlaceholderPerKind(kind: StowerLastMessageKind, expected: String) {
        let summary = StowerLastMessageSummary.make(kind: kind, text: nil)
        #expect(summary.label == expected)
        #expect(summary.isPlaceholder)
    }

    @Test(
        "empty and whitespace-only text are treated as non-text placeholders",
        arguments: ["", "   ", "\n\t  "]
    )
    internal func blankTextYieldsPlaceholder(blank: String) {
        let summary = StowerLastMessageSummary.make(kind: .attachment, text: blank)
        #expect(summary.label == "Sent an attachment")
        #expect(summary.isPlaceholder)
    }

    @Test("whitespace-padded real text stays verbatim (not trimmed to a placeholder)")
    internal func paddedRealTextStaysVerbatim() {
        let summary = StowerLastMessageSummary.make(kind: .text, text: "  hi  ")
        #expect(summary.label == "  hi  ")
        #expect(summary.isPlaceholder == false)
    }
}
