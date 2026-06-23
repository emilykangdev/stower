import Foundation
import Observation

/// The presentation phase a thread view switches on.
internal enum StowerThreadPhase: Sendable, Equatable {
    /// Loading the conversation's recent messages.
    case loading

    /// Loaded with at least one line.
    case loaded

    /// Loaded but the conversation has no readable messages.
    case empty

    /// An unexpected, non-routed failure reading the thread.
    case error
}

/// Owns the tap-through thread state for one selected row.
///
/// Holds the selected `StowerBoardRow` (the source of `chatID` and `deepLink`),
/// the loaded lines in `recentMessages` order (never re-sorted, I11), and the same
/// generation/cancellation discipline as the board view-model so a re-tap or
/// dismiss drops a stale load (I13).
@MainActor
@Observable
internal final class StowerThreadViewModel {
    /// The presentation phase the view renders.
    internal private(set) var phase: StowerThreadPhase = .loading

    /// The loaded thread lines, oldest-first.
    internal private(set) var lines: [StowerThreadLine] = []

    /// The selected row (deep-link source and thread header).
    internal let row: StowerBoardRow

    private let dataSource: any StowerBoardDataSource
    private let opener: StowerMessagesLinkOpener
    private let onFailure: @MainActor (StowerStartupFailure) -> Void
    private let clock: @Sendable () -> Date
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    /// Whether "Open in Messages" is enabled — exactly the row's deep-link rule.
    internal var canOpenInMessages: Bool { row.canOpenInMessages }

    /// Creates a thread view-model for `row`.
    ///
    /// - Parameters:
    ///   - row: The tapped board row.
    ///   - dataSource: The app-owned board boundary.
    ///   - opener: The Messages deep-link opener.
    ///   - onFailure: Routes a thread failure back to the startup model.
    ///   - clock: Supplies `now`; injectable for determinism (unused by the read,
    ///     kept for parity with the board view-model).
    internal init(
        row: StowerBoardRow,
        dataSource: any StowerBoardDataSource,
        opener: StowerMessagesLinkOpener = StowerMessagesLinkOpener(),
        onFailure: @escaping @MainActor (StowerStartupFailure) -> Void,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.row = row
        self.dataSource = dataSource
        self.opener = opener
        self.onFailure = onFailure
        self.clock = clock
    }

    /// Loads the thread when the view is presented.
    internal func onAppear() {
        load()
    }

    /// Opens the engine-supplied deep link; a no-op when the row has none.
    ///
    /// The testable seam for "Open in Messages" (I3b): it hands the row's
    /// `deepLink` straight to the opener and does nothing else; the app never
    /// constructs the URL.
    internal func openInMessages() {
        guard let url = row.deepLink else { return }
        _ = opener.openLink(url)
    }

    /// Cancels an in-flight load when the thread view disappears.
    ///
    /// Bumps the generation so a load that returns AFTER cancellation fails `runLoad`'s
    /// generation guard and can't apply stale `lines`/`phase` — cancelling the task
    /// alone isn't enough, since a near-complete load may ignore cancellation and still
    /// commit. Same discipline as the board view-model's `cancel()`.
    internal func cancel() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
    }

    /// The in-flight load task, exposed so tests can await it.
    internal var loadTaskHandle: Task<Void, Never>? { loadTask }

    /// Loads the thread under a fresh generation token (I13).
    internal func load() {
        generation += 1
        let generation = self.generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.runLoad(generation: generation)
        }
    }

    private func runLoad(generation: Int) async {
        do {
            let loaded = try await dataSource.thread(chatID: row.chatID, limit: Self.threadLimit)
            guard generation == self.generation else { return }
            lines = loaded
            phase = loaded.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            // Superseded / dismissed — never a failure.
        } catch let failure as StowerStartupFailure {
            guard generation == self.generation else { return }
            onFailure(failure)
        } catch {
            guard generation == self.generation else { return }
            phase = .error
        }
    }

    /// The newest-N messages to read, matching the reader's `threadMessages` default.
    private static let threadLimit = 100
}
