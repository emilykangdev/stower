import Foundation
import StowerMessages

/// The production `StowerBoardDataSource` — the engine-coupled board adapter.
///
/// One of the four files in `StowerMacUI` that import the engine. It holds the
/// shared `StowerDebtBoardProviding` (the same instance the startup adapter holds,
/// built once by `StowerMessagesComposition`), and maps the engine's board /
/// thread / refresh results into the app-owned view-model types via
/// `StowerMessagesMapping`. It catches `StowerMessagesError` and throws the
/// app-owned `StowerStartupFailure`, so the engine error type never crosses the
/// seam; `CancellationError` propagates unchanged (a superseded load is not a
/// failure).
internal struct StowerLiveBoardDataSource: StowerBoardDataSource {
    private let engine: any StowerDebtBoardProviding
    private let triage: any StowerTriageStoring
    private let makeContactsResolver: @Sendable () -> StowerContactsResolver

    /// Injects the shared engine conformer, the triage store, and the resolver factory.
    ///
    /// - Parameters:
    ///   - engine: The shared engine conformer (the real provider in production, a
    ///     fake engine in adapter tests).
    ///   - triage: The app-owned triage boundary (dismiss + mute). Defaults to an
    ///     empty in-memory store so previews/older tests apply no filter.
    ///   - makeContactsResolver: Builds the handle→name resolver; defaults to
    ///     `StowerContactsResolver.live()`, which re-reads Contacts authorization on
    ///     every call, so a post-grant reload self-heals to names with no rebuild
    ///     logic. It is called **once per `loadBoard`** (never per row); tests inject
    ///     a counting/empty factory.
    internal init(
        engine: any StowerDebtBoardProviding,
        triage: any StowerTriageStoring = StowerInMemoryTriageStore(),
        makeContactsResolver: @escaping @Sendable () -> StowerContactsResolver = { .live() }
    ) {
        self.engine = engine
        self.triage = triage
        self.makeContactsResolver = makeContactsResolver
    }

    internal func loadBoard(
        config: StowerStartupDebtConfig,
        now: Date
    ) async throws -> StowerBoardModel {
        do {
            let board = try await engine.loadDebtBoard(
                config: StowerMessagesMapping.mapConfig(config),
                now: now
            )
            // Apply the user's app-local triage (mute + self-expiring dismiss) as a
            // display-time post-filter, so the engine stays a pure projection of the
            // Messages database (JC4). Done before the empty-check so an all-muted
            // board skips the resolver too.
            let (neglected, ghosted) = await applyTriage(to: board, now: now)
            // No rows to label — skip building the resolver entirely. `.live()`
            // enumerates the whole address book, and the cold-start / caught-up path
            // loads an empty board repeatedly; enumerating Contacts for zero rows is
            // pure waste.
            guard !neglected.isEmpty || !ghosted.isEmpty else {
                return StowerBoardModel(neglected: [], ghosted: [])
            }
            // Built once per load (not per row): calling `.live()` inside the row map
            // would be O(rows × contacts).
            let contacts = makeContactsResolver()
            return StowerBoardModel(
                neglected: neglected.map {
                    StowerMessagesMapping.mapRow($0, now: now, contacts: contacts)
                },
                ghosted: ghosted.map {
                    StowerMessagesMapping.mapRow($0, now: now, contacts: contacts)
                }
            )
        } catch let error as StowerMessagesError {
            throw StowerMessagesMapping.mapError(error)
        }
    }

    /// Filters both lenses by the user's triage, retiring self-expired dismissals.
    ///
    /// ALL-OR-NOTHING (I4): if reading either triage set fails, the board degrades to
    /// the fully UNFILTERED board — every mute/dismissal applied, or none — never a
    /// confusing partial filter, never a crash. The retire MOVE is best-effort
    /// (`try?`): a failed retire still shows the row (a newer message already proved
    /// it) and self-heals next load; it must never fail the board load.
    private func applyTriage(
        to board: StowerDebtBoard,
        now: Date
    ) async -> (neglected: [StowerDebtItem], ghosted: [StowerDebtItem]) {
        let dismissed: [String: StowerDismissedAnchor]
        let muted: Set<String>
        do {
            dismissed = try await triage.dismissedMessages()
            muted = try await triage.muted()
        } catch {
            return (board.neglected, board.ghosted)
        }
        let neglected = await keep(board.neglected, dismissed: dismissed, muted: muted, now: now)
        let ghosted = await keep(board.ghosted, dismissed: dismissed, muted: muted, now: now)
        return (neglected, ghosted)
    }

    /// Keeps the items that are neither muted nor still-actively dismissed.
    ///
    /// A muted handle is hidden regardless of anchor. A dismissed handle stays hidden
    /// until a STRICTLY-newer message arrives (`lastMessageTimestamp > anchorTimestamp`)
    /// — at which point the row returns and its stale dismissal is best-effort retired.
    private func keep(
        _ items: [StowerDebtItem],
        dismissed: [String: StowerDismissedAnchor],
        muted: Set<String>,
        now: Date
    ) async -> [StowerDebtItem] {
        var kept: [StowerDebtItem] = []
        kept.reserveCapacity(items.count)
        for item in items {
            let handleKey = StowerDraftKey.derive(forHandle: item.counterpartHandle)
            if muted.contains(handleKey) { continue }
            if let anchor = dismissed[handleKey] {
                if item.lastMessageTimestamp <= anchor.anchorTimestamp { continue }
                try? await triage.retireDismissal(
                    handleKey: handleKey,
                    messageGUID: anchor.messageGUID,
                    anchorTimestamp: anchor.anchorTimestamp,
                    at: now
                )
            }
            kept.append(item)
        }
        return kept
    }

    internal func mutedSenders() async -> [StowerMutedSender] {
        let mutedKeys: Set<String>
        let dismissed: [String: StowerDismissedAnchor]
        do {
            mutedKeys = try await triage.muted()
            dismissed = try await triage.dismissedMessages()
        } catch {
            // Degrade to empty (I4 posture): never surface a triage read error to the
            // popover. A transient failure self-heals on the next open.
            return []
        }
        guard !mutedKeys.isEmpty else { return [] }
        // Built once (not per key): `.live()` enumerates the whole address book.
        let contacts = makeContactsResolver()
        // `isActivelyDismissed` cross-references the raw `dismissed_message` set, per the
        // plan's settled Dismiss×mute design (the pill warns "still hidden by a dismissal"
        // before unmute). KNOWN benign limitation: if a strictly-newer message arrived but
        // no board load has retired the stale dismissal yet, the pill may over-show — the
        // harmless direction (unmuting then reveals the person; the pill never FAILS to
        // warn for a genuinely-active dismissal, which is the surprise it guards against).
        // Making it exact would require loading per-conversation timestamps here, which
        // this bounded current-state query deliberately avoids.
        return mutedKeys.map { key in
            StowerMutedSender(
                key: key,
                displayName: contacts.displayName(forKey: key),
                hasResolvedName: contacts.hasName(forKey: key),
                isActivelyDismissed: dismissed[key] != nil
            )
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    internal func thread(chatID: String, limit: Int) async throws -> [StowerThreadLine] {
        do {
            let messages = try await engine.recentMessages(chatID: chatID, limit: limit)
            return StowerMessagesMapping.mapThread(messages)
        } catch let error as StowerMessagesError {
            throw StowerMessagesMapping.mapError(error)
        }
    }

    internal func refreshJudgments(
        config: StowerStartupDebtConfig,
        now: Date
    ) async throws -> StowerBoardRefreshOutcome {
        do {
            let summary = try await engine.refreshJudgments(
                config: StowerMessagesMapping.mapConfig(config),
                now: now
            )
            return StowerMessagesMapping.mapRefresh(summary)
        } catch let error as StowerMessagesError {
            throw StowerMessagesMapping.mapError(error)
        }
    }
}
