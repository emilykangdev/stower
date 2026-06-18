import Foundation
import Testing

@testable import StowerMacUI

/// "Open in Messages" (I3b): the action hands the row's `deepLink` straight to the
/// injected opener and does nothing else — it never fires on a `nil`-link row, and
/// the app never constructs the URL. Exercised through `StowerThreadViewModel`'s
/// `openInMessages()` seam with a recording opener.
@MainActor
@Suite internal struct StowerMessagesLinkOpenerTests {
    /// Records the URLs an opener is handed instead of launching Messages.
    private final class OpenerRecorder {
        var opened: [URL] = []
    }

    private func makeOpener(_ recorder: OpenerRecorder) -> StowerMessagesLinkOpener {
        StowerMessagesLinkOpener(open: { url in
            recorder.opened.append(url)
            return true
        })
    }

    private func threadModel(
        deepLink: URL?,
        opener: StowerMessagesLinkOpener
    ) -> StowerThreadViewModel {
        let row = StowerBoardRow(
            chatID: "chat-1",
            counterpart: "Alex",
            counterpartHandle: "+14155550100",
            monogram: "A",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 1,
            deepLink: deepLink
        )
        return StowerThreadViewModel(
            row: row,
            dataSource: StowerSpyBoardDataSource(),
            opener: opener,
            onFailure: { _ in }
        )
    }

    @Test("an enabled row opens exactly its deepLink, once")
    internal func enabledRowOpensDeepLink() {
        let recorder = OpenerRecorder()
        let url = URL(string: "sms:+14155550100")
        let model = threadModel(deepLink: url, opener: makeOpener(recorder))

        #expect(model.canOpenInMessages)
        model.openInMessages()
        #expect(recorder.opened == [url])
    }

    @Test("a nil-deepLink row never opens anything")
    internal func disabledRowOpensNothing() {
        let recorder = OpenerRecorder()
        let model = threadModel(deepLink: nil, opener: makeOpener(recorder))

        #expect(model.canOpenInMessages == false)
        model.openInMessages()
        #expect(recorder.opened.isEmpty)
    }
}
