import Foundation
import Observation

/// The observable state behind the feedback sheet: the typed message/email, the
/// send phase, and the send + analytics wiring.
///
/// Constructed once as `@State` in `StowerRootView` and injected into the board,
/// so an in-progress message survives a re-render (never re-created inline in a
/// view body). The `client`, `metadata` provider, and `analyticsReporter` are
/// injected so the send path is unit-tested without the network or a live bundle.
///
/// The message and email are user-authored content and NEVER reach analytics —
/// `feedback_opened`/`feedback_sent` carry only the coarse `licenseStatus`
/// (I-AnalyticsNoPII).
@MainActor
@Observable
internal final class StowerFeedbackModel {
    /// The send lifecycle: idle → sending → sent | failed; a failure returns to
    /// sending on Retry with the text preserved.
    internal enum Phase: Sendable, Equatable {
        case idle
        case sending
        case sent
        case failed
    }

    /// The typed feedback message (bound to the sheet's multi-line field).
    internal var message = ""

    /// The typed optional reply email (bound to the sheet's email field).
    internal var email = ""

    /// The current send phase.
    internal private(set) var phase: Phase = .idle

    private let client: StowerFeedbackClient
    private let metadata: @MainActor () -> StowerFeedbackMetadata
    private let analyticsReporter: any StowerAnalyticsReporting

    /// Bumped on every `reset()` so an in-flight `send()` whose sheet was
    /// dismissed mid-request can detect it is stale and drop its result instead
    /// of writing `.sent`/`.failed` onto a model the next open will reuse.
    private var sendGeneration = 0

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - client: The feedback POST client.
    ///   - metadata: A provider read at send time, so `licenseStatus`/`instanceID`
    ///     reflect the current license state (a mid-trial activation flips it).
    ///   - analyticsReporter: The analytics seam `feedback_opened`/`feedback_sent`
    ///     report through.
    internal init(
        client: StowerFeedbackClient,
        metadata: @escaping @MainActor () -> StowerFeedbackMetadata,
        analyticsReporter: any StowerAnalyticsReporting
    ) {
        self.client = client
        self.metadata = metadata
        self.analyticsReporter = analyticsReporter
    }

    /// The trimmed message (leading/trailing whitespace and newlines removed).
    internal var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether Send is enabled: not already sending, a non-empty trimmed message,
    /// and within the character cap.
    internal var canSend: Bool {
        phase != .sending
            && !trimmedMessage.isEmpty
            && message.count <= Self.messageCharLimit
    }

    /// Reports `feedback_opened` — called from the sheet's `onAppear`.
    ///
    /// Carries only the coarse `licenseStatus`; never the message, email, or
    /// `instanceID`.
    internal func markOpened() {
        analyticsReporter.report(.feedbackOpened(licenseStatus: metadata().licenseStatus.rawValue))
    }

    /// Resets the sheet to a fresh `.idle` state with cleared fields.
    ///
    /// The model is injected once and reused, so a dismiss (Done after a
    /// successful send, or Cancel) must clear the phase and text — otherwise the
    /// next open would still show the `.sent` confirmation and refuse a second
    /// message.
    internal func reset() {
        sendGeneration += 1
        message = ""
        email = ""
        phase = .idle
    }

    /// Sends the current message + optional email, classifying the result.
    ///
    /// No-ops unless `canSend`. A blank email is mapped to `nil` so it encodes as
    /// JSON `null`. On `.sent`, fires `feedback_sent`; on `.failed`, leaves
    /// `message`/`email` intact so the user's text is never lost (I-FailurePreservesText).
    internal func send() async {
        guard canSend else { return }
        let generation = sendGeneration
        phase = .sending
        let meta = metadata()
        let submission = StowerFeedbackSubmission(
            message: trimmedMessage,
            email: email.stowerBlankAsNil,
            instanceID: meta.instanceID,
            appVersion: meta.appVersion,
            osVersion: meta.osVersion,
            licenseStatus: meta.licenseStatus
        )
        let result = await client.send(submission)
        // The sheet was dismissed (reset) while this request was in flight — drop
        // the result so it can't stamp .sent/.failed onto the reused model.
        guard generation == sendGeneration else { return }
        phase = result == .sent ? .sent : .failed
        if result == .sent {
            analyticsReporter.report(.feedbackSent(licenseStatus: meta.licenseStatus.rawValue))
        }
    }

    /// The hard message-length ceiling; Send is disabled over this (JC4), and the
    /// Deno relay's size cap can't bounce a long message after a round-trip.
    internal static let messageCharLimit = 5000
}

extension String {
    /// The string trimmed, or `nil` if that leaves it empty — so a blank reply
    /// email encodes as JSON `null`, not `""` (I-BlankEmailNull).
    fileprivate var stowerBlankAsNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
