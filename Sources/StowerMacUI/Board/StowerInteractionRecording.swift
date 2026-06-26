import Foundation

/// One semantic board interaction in app-owned terms, recorded as user memory.
///
/// The app-owned mirror of the engine's `StowerInteractionEvent`, adapted at the
/// composition seam so the view/board layer never imports `StowerMessages`. Built in
/// `StowerBoardViewModel` action methods (never in SwiftUI view closures) and handed
/// to `StowerInteractionRecording`. This is semantic INTENT, not view telemetry.
internal enum StowerBoardInteractionEvent: Sendable, Equatable {
    /// The user dismissed one message on `boardTab` (surface is always the board).
    case messageDismissed(
        handleKey: String,
        messageGUID: String,
        boardTab: String,
        occurredAt: Date
    )

    /// The user muted a sender from `surface` (`board` or `muted_senders`).
    case senderMuted(handleKey: String, surface: String, occurredAt: Date)

    /// The user unmuted a sender from `surface` (`board` or `muted_senders`).
    case senderUnmuted(handleKey: String, surface: String, occurredAt: Date)
}

/// The app-owned boundary the board records semantic interaction events through.
///
/// Mirrors how `StowerTriageStoring` fronts the precious triage store: the view layer
/// depends on this app-owned protocol, and the composition adapts the precious
/// `StowerMessages.StowerInteractionEventStore` to it. `record` is NON-throwing by
/// contract — recording is a side log that must NEVER block or roll back the triage
/// action it accompanies; the live adapter swallows and logs store failures.
internal protocol StowerInteractionRecording: Sendable {
    /// Appends one semantic event; failures are swallowed (never block the action).
    func record(_ event: StowerBoardInteractionEvent) async
}

/// A recorder that drops every event — the default for previews and most tests.
///
/// Production injects the live adapter from the composition; a no-op keeps previews
/// and tests that don't assert on events off the disk entirely.
internal struct StowerNoOpInteractionRecorder: StowerInteractionRecording {
    internal func record(_ event: StowerBoardInteractionEvent) async {}
}

/// An in-memory spy recorder for tests that assert which semantic events fired.
///
/// Records every event in order; never touches the disk. Production never uses it.
internal actor StowerInMemoryInteractionRecorder: StowerInteractionRecording {
    private var events: [StowerBoardInteractionEvent] = []

    internal init() {}

    internal func record(_ event: StowerBoardInteractionEvent) {
        events.append(event)
    }

    /// The events recorded so far, oldest first.
    internal func recorded() -> [StowerBoardInteractionEvent] {
        events
    }
}
