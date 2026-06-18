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
    private let makeContactsResolver: @Sendable () -> StowerContactsResolver

    /// Injects the shared engine conformer and the contacts-resolver factory.
    ///
    /// - Parameters:
    ///   - engine: The shared engine conformer (the real provider in production, a
    ///     fake engine in adapter tests).
    ///   - makeContactsResolver: Builds the handle→name resolver; defaults to
    ///     `StowerContactsResolver.live()`, which re-reads Contacts authorization on
    ///     every call, so a post-grant reload self-heals to names with no rebuild
    ///     logic. It is called **once per `loadBoard`** (never per row); tests inject
    ///     a counting/empty factory.
    internal init(
        engine: any StowerDebtBoardProviding,
        makeContactsResolver: @escaping @Sendable () -> StowerContactsResolver = { .live() }
    ) {
        self.engine = engine
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
            // Built once per load (not per row): `.live()` enumerates the whole
            // address book, so calling it inside the row map would be O(rows × contacts).
            let contacts = makeContactsResolver()
            return StowerBoardModel(
                neglected: board.neglected.map {
                    StowerMessagesMapping.mapRow($0, now: now, contacts: contacts)
                },
                ghosted: board.ghosted.map {
                    StowerMessagesMapping.mapRow($0, now: now, contacts: contacts)
                }
            )
        } catch let error as StowerMessagesError {
            throw StowerMessagesMapping.mapError(error)
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
