import Foundation
import Testing

@testable import StowerMacUI

/// The model's send behavior.
///
/// A failure preserves the typed text (I-FailurePreservesText), and
/// `canSend`/`send` guard empty/whitespace/over-cap messages (I-EmptyGuard).
/// Analytics fire only on success, carrying no PII.
@MainActor
@Suite internal struct StowerFeedbackModelTests {

    private func metadata() -> StowerFeedbackMetadata {
        StowerFeedbackMetadata(
            instanceID: "inst-1",
            licenseStatus: .paid,
            appVersion: "1.0 (1)",
            osVersion: "macOS 15.4"
        )
    }

    /// A model whose client always returns `result`, wired to a spy reporter.
    private func model(
        result: StowerFeedbackSendResult,
        reporter: StowerInMemoryAnalyticsReporter = StowerInMemoryAnalyticsReporter()
    ) throws -> StowerFeedbackModel {
        let url = try #require(URL(string: "https://relay.invalid/feedback"))
        let status = result == .sent ? 200 : 500
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        let client = StowerFeedbackClient(
            endpointURL: "https://relay.invalid/feedback",
            transport: { _ in (Data(), response) }
        )
        return StowerFeedbackModel(
            client: client,
            metadata: { self.metadata() },
            analyticsReporter: reporter
        )
    }

    @Test("I-FailurePreservesText: a failed send leaves message/email intact, phase == .failed")
    internal func failurePreservesText() async throws {
        let model = try model(result: .failed)
        model.message = "Something's off"
        model.email = "me@example.com"

        model.send()
        await model.sendTaskHandle?.value

        #expect(model.phase == .failed)
        #expect(model.message == "Something's off")
        #expect(model.email == "me@example.com")
    }

    @Test("a successful send sets phase == .sent")
    internal func successSetsSent() async throws {
        let model = try model(result: .sent)
        model.message = "Nice work"

        model.send()
        await model.sendTaskHandle?.value

        #expect(model.phase == .sent)
    }

    @Test("a reset during an in-flight send drops the stale result, leaving phase == .idle")
    internal func resetDuringSendDropsStaleResult() async throws {
        let gate = StowerSendGate()
        let url = try #require(URL(string: "https://relay.invalid/feedback"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        let client = StowerFeedbackClient(
            endpointURL: "https://relay.invalid/feedback",
            transport: { _ in
                await gate.wait()
                return (Data(), response)
            }
        )
        let model = StowerFeedbackModel(
            client: client,
            metadata: { self.metadata() },
            analyticsReporter: StowerInMemoryAnalyticsReporter()
        )
        model.message = "In flight"

        model.send()
        let sending = model.sendTaskHandle
        // Let send() reach .sending and block in the transport, then dismiss —
        // reset() cancels the task and bumps the generation.
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(model.phase == .sending)
        model.reset()
        await gate.open()
        await sending?.value

        // The stale 200 must NOT have stamped .sent onto the reused model.
        #expect(model.phase == .idle)
    }

    @Test("reset() clears text and returns to .idle so the reused model sends again")
    internal func resetClearsStateAfterSend() async throws {
        let model = try model(result: .sent)
        model.message = "First note"
        model.email = "me@example.com"
        model.send()
        await model.sendTaskHandle?.value
        #expect(model.phase == .sent)

        model.reset()

        #expect(model.phase == .idle)
        #expect(model.message == "")
        #expect(model.email == "")
        #expect(model.canSend == false)
    }

    @Test("I-EmptyGuard: canSend is false for empty and whitespace-only messages")
    internal func emptyMessageBlocksSend() throws {
        let model = try model(result: .sent)
        model.message = ""
        #expect(model.canSend == false)
        model.message = "   \n  "
        #expect(model.canSend == false)
    }

    @Test("I-EmptyGuard: canSend is false over the character cap")
    internal func overCapBlocksSend() throws {
        let model = try model(result: .sent)
        model.message = String(repeating: "a", count: StowerFeedbackModel.messageCharLimit + 1)
        #expect(model.canSend == false)
        model.message = String(repeating: "a", count: StowerFeedbackModel.messageCharLimit)
        #expect(model.canSend == true)
    }

    @Test("I-EmptyGuard: the cap is measured against the trimmed message, not the raw one")
    internal func capMeasuresTrimmedMessage() throws {
        let model = try model(result: .sent)
        // At the cap after trimming, but over it raw (surrounding whitespace).
        // The trimmed string is exactly what performSend submits, so this must send.
        let atCap = String(repeating: "a", count: StowerFeedbackModel.messageCharLimit)
        model.message = "  \n\(atCap)\n  "
        #expect(model.message.count > StowerFeedbackModel.messageCharLimit)
        #expect(model.canSend == true)
    }

    @Test("I-EmptyGuard: send() on an empty message no-ops, leaving phase == .idle")
    internal func emptySendNoOps() async throws {
        let model = try model(result: .sent)
        model.message = "   "

        model.send()
        await model.sendTaskHandle?.value

        #expect(model.phase == .idle)
    }

    @Test("I-AnalyticsNoPII: feedback_sent fires on success carrying only license_status")
    internal func sentFiresAnalyticsNoPII() async throws {
        let reporter = StowerInMemoryAnalyticsReporter()
        let model = try model(result: .sent, reporter: reporter)
        model.message = "Loving it"
        model.email = "me@example.com"

        model.send()
        await model.sendTaskHandle?.value

        let sent = reporter.recorded().filter { $0.signalName == "feedback_sent" }
        #expect(sent.count == 1)
        let params = try #require(sent.first?.parameters)
        #expect(params["license_status"] == "paid")
        // No PII leaked into the event.
        #expect(params.count == 1)
        #expect(!params.values.contains("me@example.com"))
        #expect(!params.values.contains("Loving it"))
        #expect(!params.values.contains("inst-1"))
    }

    @Test("a failed send fires no feedback_sent event")
    internal func failureFiresNoSent() async throws {
        let reporter = StowerInMemoryAnalyticsReporter()
        let model = try model(result: .failed, reporter: reporter)
        model.message = "hi"

        model.send()
        await model.sendTaskHandle?.value

        #expect(reporter.recorded().filter { $0.signalName == "feedback_sent" }.isEmpty)
    }

    @Test("I-AnalyticsNoPII: markOpened fires feedback_opened carrying only license_status")
    internal func markOpenedFiresNoPII() throws {
        let reporter = StowerInMemoryAnalyticsReporter()
        let model = try model(result: .sent, reporter: reporter)

        model.markOpened()

        let opened = reporter.recorded().filter { $0.signalName == "feedback_opened" }
        #expect(opened.count == 1)
        let params = try #require(opened.first?.parameters)
        #expect(params["license_status"] == "paid")
        #expect(params.count == 1)
    }
}

/// A one-shot gate so a test can hold a stub transport mid-request, dismiss the
/// sheet, then release it — reproducing the send-then-reset race.
private actor StowerSendGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
