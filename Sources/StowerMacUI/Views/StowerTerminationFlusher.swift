import Foundation

/// Lets the app delegate drain the board's in-flight draft writes on quit.
///
/// `StowerMacApp.swift` (outside the SPM tree) holds one of these, hands it to
/// `StowerRootView`, and awaits `flushPendingWork()` from `applicationShouldTerminate`
/// so a graceful quit loses no draft (JC2). The tested guarantee is
/// `StowerBoardViewModel.flushAll()`; this is the thin lifecycle wire to it.
@MainActor
public final class StowerTerminationFlusher {
    private var flush: (@MainActor () async -> Void)?

    /// Creates a flusher with no work wired yet.
    public init() {}

    /// Wires the work to run on termination (the board view-model's `flushAll`).
    internal func onFlush(_ flush: @escaping @MainActor () async -> Void) {
        self.flush = flush
    }

    /// Awaits the wired termination work; a no-op if nothing was wired.
    public func flushPendingWork() async {
        await flush?()
    }
}
