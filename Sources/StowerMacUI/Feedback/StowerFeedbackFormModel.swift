import Foundation
import Observation

/// The form-state model for the feedback sheet.
///
/// Owns all mutable state (`text`, `email`, `isSending`, `errorMessage`,
/// `didSend`) and the `send()` action so the SwiftUI view is a thin renderer.
/// The `onSubmit` closure is injected, making the send path unit-testable
/// without SwiftUI or network access (I4/I5).
@MainActor
@Observable
internal final class StowerFeedbackFormModel {
    /// The user's feedback text.
    internal var text: String = ""

    /// The user's optional reply email, blank when left empty.
    ///
    /// The form model sends `email.nilIfBlank` to the draft so a whitespace-only
    /// value is treated the same as empty — omitted from the JSON payload.
    internal var email: String = ""

    /// Whether a submission is in flight.
    internal private(set) var isSending: Bool = false

    /// The retryable error message shown in the sheet, or `nil` when no error.
    internal private(set) var errorMessage: String?

    /// Set to `true` once the server accepts the submission.
    ///
    /// The view observes this to dismiss the sheet and trigger the board-level
    /// success confirmation. It is never reset — the model is discarded after use.
    internal private(set) var didSend: Bool = false

    /// The maximum character count the sheet enforces (soft guard against
    /// pasting a novel into a public unauthenticated endpoint).
    internal static let maxTextLength = 5_000

    /// Whether the Send button should be enabled.
    ///
    /// False when the text is blank/whitespace-only, when the text exceeds the
    /// soft cap, or when a send is already in flight.
    internal var canSend: Bool {
        !text.trimmed.isEmpty && text.count <= Self.maxTextLength && !isSending
    }

    private let onSubmit: (StowerFeedbackDraft) async -> StowerFeedbackResult
    private let appVersion: String

    /// The Keygen license resource id attached to submissions, or `nil` when no lease exists.
    ///
    /// Exposed so the view can show the disclosure line only when a lease is present (A4).
    internal let licenseID: String?

    /// Creates the form model.
    ///
    /// - Parameters:
    ///   - licenseID: The Keygen license resource id to attach to every
    ///     submission, or `nil` when no lease exists (anonymous send, A4).
    ///   - appVersion: The app version string included in every payload.
    ///   - onSubmit: The submission closure (the client's `send(draft:)` in
    ///     production; a spy in tests).
    internal init(
        licenseID: String?,
        appVersion: String,
        onSubmit: @escaping (StowerFeedbackDraft) async -> StowerFeedbackResult
    ) {
        self.licenseID = licenseID
        self.appVersion = appVersion
        self.onSubmit = onSubmit
    }

    /// Submits the current form state.
    ///
    /// A no-op when `canSend` is false (blank text or already sending). On
    /// `.sent` sets `didSend`; on `.failed` sets `errorMessage` and preserves
    /// `text` for retry. The model never resets `didSend` — the sheet is
    /// expected to dismiss once it observes `true`.
    internal func send() async {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        let draft = StowerFeedbackDraft(
            text: text,
            email: email.nilIfBlank,
            licenseID: licenseID,
            appVersion: appVersion
        )
        switch await onSubmit(draft) {
        case .sent:
            isSending = false
            didSend = true
        case .failed:
            isSending = false
            errorMessage = Self.genericErrorMessage
        }
    }

    private static let genericErrorMessage =
        "Couldn't send — check your connection and try again."
}

extension String {
    /// The string with leading and trailing whitespace stripped.
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `nil` when the string is blank (empty or whitespace-only); `self` otherwise.
    internal var nilIfBlank: String? { trimmed.isEmpty ? nil : self }
}
