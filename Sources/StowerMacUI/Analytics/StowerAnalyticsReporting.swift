import Foundation

/// The app-owned analytics boundary.
///
/// All analytics emission flows through this synchronous, non-throwing seam.
/// Conformers must be `Sendable`: reports arrive from `@MainActor` view models
/// AND from the quit path (`applicationShouldTerminate`), so the reporter must
/// be safe to call from any context.
///
/// Synchronous by design (Eng F4): `TelemetryDeck.signal` is static +
/// thread-safe, and `session_ended` at quit must not `await` or the quit
/// path would block.
internal protocol StowerAnalyticsReporting: Sendable {
    /// Emits one analytics event; never throws, never blocks the caller.
    func report(_ event: StowerAnalyticsEvent)
}

/// A reporter that drops every event — the default for previews and most tests.
///
/// Production injects the live `StowerTelemetryDeckReporter`; a no-op keeps
/// previews and tests that don't assert on analytics off the network entirely.
internal struct StowerNoOpAnalyticsReporter: StowerAnalyticsReporting {
    internal func report(_ event: StowerAnalyticsEvent) {}
}

/// An in-memory spy reporter for tests that assert which events fired.
///
/// Lock-guarded `final class` (not an actor) so callers from `@MainActor`
/// view models can read `recorded()` synchronously in test assertions (Eng F4).
internal final class StowerInMemoryAnalyticsReporter: StowerAnalyticsReporting {
    private let lock = NSLock()
    private var events: [StowerAnalyticsEvent] = []

    internal init() {}

    internal func report(_ event: StowerAnalyticsEvent) {
        lock.withLock { events.append(event) }
    }

    /// The events recorded so far, oldest first.
    internal func recorded() -> [StowerAnalyticsEvent] {
        lock.withLock { events }
    }

    /// Empties the recorded events.
    internal func reset() {
        lock.withLock { events.removeAll() }
    }
}

extension StowerInMemoryAnalyticsReporter: @unchecked Sendable {}
