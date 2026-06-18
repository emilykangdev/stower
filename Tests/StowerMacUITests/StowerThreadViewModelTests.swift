import Foundation
import Testing

@testable import StowerMacUI

/// The thread view-model's load, empty, and failure behaviors.
///
/// It surfaces lines in `recentMessages` order, marks an empty thread as empty
/// (not a blank loaded pane), and routes a thrown `StowerStartupFailure` via
/// `onFailure` so an FDA/source loss re-enters onboarding. Driven by
/// `StowerSpyBoardDataSource` — no engine, no real model.
@MainActor
@Suite internal struct StowerThreadViewModelTests {
    private final class FailureRecorder {
        var failures: [StowerStartupFailure] = []
    }

    private func makeRow() -> StowerBoardRow {
        StowerBoardRow(
            chatID: "chat-1",
            counterpart: "Alex",
            counterpartHandle: "+14155550100",
            monogram: "A",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 2,
            deepLink: nil
        )
    }

    private func line(id: String, isFromMe: Bool, isMostRecent: Bool) -> StowerThreadLine {
        StowerThreadLine(
            id: id,
            isFromMe: isFromMe,
            summary: StowerLastMessageSummary.make(kind: .text, text: id),
            isMostRecent: isMostRecent
        )
    }

    @Test("the thread view-model surfaces lines in order and marks loaded")
    internal func threadLoadsLines() async {
        let spy = StowerSpyBoardDataSource()
        spy.threadLines = [
            line(id: "m1", isFromMe: false, isMostRecent: false),
            line(id: "m2", isFromMe: true, isMostRecent: true)
        ]
        let model = StowerThreadViewModel(row: makeRow(), dataSource: spy, onFailure: { _ in })

        model.onAppear()
        await model.loadTaskHandle?.value

        #expect(model.lines.map(\.id) == ["m1", "m2"])
        #expect(model.phase == .loaded)
        #expect(spy.threadCallCount == 1)
    }

    @Test("an empty thread renders the empty state, not a blank loaded pane")
    internal func threadEmptyState() async {
        let spy = StowerSpyBoardDataSource()
        spy.threadLines = []
        let model = StowerThreadViewModel(row: makeRow(), dataSource: spy, onFailure: { _ in })

        model.onAppear()
        await model.loadTaskHandle?.value

        #expect(model.phase == .empty)
    }

    @Test("a thread StowerStartupFailure routes via onFailure (re-enters onboarding)")
    internal func threadFailureRoutes() async {
        let spy = StowerSpyBoardDataSource()
        spy.threadError = .unreadable
        let recorder = FailureRecorder()
        let model = StowerThreadViewModel(
            row: makeRow(),
            dataSource: spy,
            onFailure: { recorder.failures.append($0) }
        )

        model.onAppear()
        await model.loadTaskHandle?.value

        #expect(recorder.failures == [.unreadable])
    }
}
