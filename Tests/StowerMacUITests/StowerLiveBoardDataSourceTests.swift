import Foundation
import StowerMessages
import Synchronization
import Testing

@testable import StowerMacUI

/// The board adapter crosses the seam app-owned.
///
/// A `StowerMessagesError` from the engine is caught and rethrown as a
/// `StowerStartupFailure`, a clean load maps into an app-owned `StowerBoardModel`,
/// Contacts denial degrades to handles (I3), and the resolver is built once per
/// load — not per row (I6). Mirrors `StowerMessagesStartupAdapterTests` over
/// `StowerFakeMessagesEngine`.
@Suite internal struct StowerLiveBoardDataSourceTests {
    private static let handle = "+14155550100"

    private static let anchorTime = Date(timeIntervalSince1970: 1_000_000)
    private static let newerTime = Date(timeIntervalSince1970: 2_000_000)

    private static func item(chatID: String) -> StowerDebtItem {
        item(chatID: chatID, handle: handle, timestamp: anchorTime)
    }

    private static func item(
        chatID: String,
        handle: String,
        timestamp: Date
    ) -> StowerDebtItem {
        StowerDebtItem(
            chatID: chatID,
            chatTitle: "Alex",
            counterpart: handle,
            counterpartHandle: handle,
            lastMessageKind: .text,
            lastMessageText: "hello",
            lastMessageTimestamp: timestamp,
            deepLink: nil,
            replyExpectationConfidence: 0.8,
            lastMessageGUID: "guid-\(chatID)"
        )
    }

    @Test("a load error is rethrown as the app-owned failure, never StowerMessagesError")
    internal func loadErrorCrossesSeam() async throws {
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(loadError: .unreadableSource("disk error"))
        )
        do {
            _ = try await adapter.loadBoard(config: .appDefault, now: Date())
            Issue.record("the board adapter should have thrown")
        } catch let failure as StowerStartupFailure {
            #expect(failure == .unreadable)
        } catch {
            Issue.record("expected a StowerStartupFailure, got \(error)")
        }
    }

    @Test("a clean load maps the engine board into an app-owned model")
    internal func cleanLoadMapsModel() async throws {
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(),
            makeContactsResolver: { StowerContactsResolver() }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(board.isEmpty)
    }

    @Test("an empty/denied resolver degrades rows to handle counterparts without throwing (I3)")
    internal func contactsDenialDegradesToHandles() async throws {
        let engine = StowerFakeMessagesEngine(
            board: StowerDebtBoard(neglected: [Self.item(chatID: "a")], ghosted: [])
        )
        let adapter = StowerLiveBoardDataSource(
            engine: engine,
            makeContactsResolver: { StowerContactsResolver() }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(board.neglected.count == 1)
        #expect(board.neglected.first?.counterpart == Self.handle)
    }

    @Test("the resolver is built once per load, not once per row (I6)")
    internal func resolverBuiltOncePerLoad() async throws {
        let engine = StowerFakeMessagesEngine(
            board: StowerDebtBoard(
                neglected: [Self.item(chatID: "a"), Self.item(chatID: "b")],
                ghosted: [Self.item(chatID: "c")]
            )
        )
        // A synchronous, thread-safe counter the `@Sendable` factory can bump inline.
        let builds = Mutex(0)
        let adapter = StowerLiveBoardDataSource(
            engine: engine,
            makeContactsResolver: {
                builds.withLock { $0 += 1 }
                return StowerContactsResolver()
            }
        )
        // Two loads over three rows each: the factory must fire exactly twice (M loads),
        // never N×M (which would be 6).
        _ = try await adapter.loadBoard(config: .appDefault, now: Date())
        _ = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(builds.withLock { $0 } == 2)
    }

    @Test("an empty board never builds the resolver (no Contacts enumeration for zero rows)")
    internal func emptyBoardSkipsResolver() async throws {
        let builds = Mutex(0)
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(),  // default empty board
            makeContactsResolver: {
                builds.withLock { $0 += 1 }
                return StowerContactsResolver()
            }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(board.isEmpty)
        #expect(builds.withLock { $0 } == 0)
    }

    @Test("a post-grant rebuild yields names on the next load (self-heal, I6)")
    internal func secondLoadYieldsNames() async throws {
        let engine = StowerFakeMessagesEngine(
            board: StowerDebtBoard(neglected: [Self.item(chatID: "a")], ghosted: [])
        )
        // The factory returns empty on the first build (handles) and a mapped resolver
        // on the second, modeling a grant landing between loads — proving the per-load
        // rebuild self-heals to names with no relaunch.
        let builds = Mutex(0)
        let adapter = StowerLiveBoardDataSource(
            engine: engine,
            makeContactsResolver: {
                let isFirstBuild = builds.withLock { value in
                    value += 1
                    return value == 1
                }
                return isFirstBuild
                    ? StowerContactsResolver()
                    : StowerContactsResolver(mapping: [Self.handle: "Alex Rivera"])
            }
        )
        let first = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(first.neglected.first?.counterpart == Self.handle)
        let second = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(second.neglected.first?.counterpart == "Alex Rivera")
    }

    // MARK: - Triage filter (dismiss self-expiry + mute)

    private static func boardWith(_ items: [StowerDebtItem]) -> StowerDebtBoard {
        StowerDebtBoard(neglected: items, ghosted: [])
    }

    @Test("a dismissal whose anchor is not strictly older keeps the row hidden (I3)")
    internal func dismissedRowStaysHiddenUntilStrictlyNewer() async throws {
        let key = StowerDraftKey.derive(forHandle: Self.handle)
        let triage = StowerInMemoryTriageStore(
            dismissed: [
                key: StowerDismissedAnchor(messageGUID: "g1", anchorTimestamp: Self.anchorTime)
            ]
        )
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(board: Self.boardWith([Self.item(chatID: "a")])),
            triage: triage,
            makeContactsResolver: { StowerContactsResolver() }
        )
        // The board's last message has the SAME timestamp as the anchor (an edit/unsend
        // can change the GUID but not the time) → not strictly newer → still hidden.
        let board = try await adapter.loadBoard(config: .appDefault, now: Self.newerTime)
        #expect(board.isEmpty)
    }

    @Test("a strictly-newer message un-dismisses the row and retires the dismissal (I3)")
    internal func strictlyNewerMessageReturnsRowAndRetires() async throws {
        let key = StowerDraftKey.derive(forHandle: Self.handle)
        let triage = StowerInMemoryTriageStore(
            dismissed: [
                key: StowerDismissedAnchor(messageGUID: "g1", anchorTimestamp: Self.anchorTime)
            ]
        )
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(
                board: Self.boardWith([
                    Self.item(chatID: "a", handle: Self.handle, timestamp: Self.newerTime)
                ])
            ),
            triage: triage,
            makeContactsResolver: { StowerContactsResolver() }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Self.newerTime)
        #expect(board.neglected.count == 1)
        // The stale dismissal was moved out of current state during the load.
        #expect(await triage.dismissedMessages().isEmpty)
    }

    @Test("a muted handle is dropped from both lenses regardless of anchor (I7)")
    internal func mutedHandleHidden() async throws {
        let key = StowerDraftKey.derive(forHandle: Self.handle)
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(board: Self.boardWith([Self.item(chatID: "a")])),
            triage: StowerInMemoryTriageStore(muted: [key]),
            makeContactsResolver: { StowerContactsResolver() }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Self.newerTime)
        #expect(board.isEmpty)
    }

    @Test("one mute hides both transport variants of the same number (I9)")
    internal func muteIsTransportFlipStable() async throws {
        // Two differently-formatted handles for ONE number normalize to ONE key.
        let imessage = Self.item(chatID: "im", handle: "+14155550100", timestamp: Self.anchorTime)
        let sms = Self.item(chatID: "sms", handle: "+1 (415) 555-0100", timestamp: Self.anchorTime)
        let key = StowerDraftKey.derive(forHandle: "+14155550100")
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(board: Self.boardWith([imessage, sms])),
            triage: StowerInMemoryTriageStore(muted: [key]),
            makeContactsResolver: { StowerContactsResolver() }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Self.newerTime)
        #expect(board.isEmpty)
    }

    @Test("an empty triage filters nothing — the engine's rows pass through (I11)")
    internal func emptyTriageLeavesEngineOutputIntact() async throws {
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(board: Self.boardWith([Self.item(chatID: "a")])),
            triage: StowerInMemoryTriageStore(),
            makeContactsResolver: { StowerContactsResolver() }
        )
        let board = try await adapter.loadBoard(config: .appDefault, now: Self.newerTime)
        #expect(board.neglected.count == 1)
    }

    @Test("a triage read failure degrades to the fully unfiltered board (I4)")
    internal func triageReadFailureDegradesToUnfiltered() async throws {
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(
                board: StowerDebtBoard(
                    neglected: [Self.item(chatID: "a")],
                    ghosted: [Self.item(chatID: "b")]
                )
            ),
            triage: StowerThrowingTriageStore(),
            makeContactsResolver: { StowerContactsResolver() }
        )
        // Even though both rows would be muted by a working store, a throwing store
        // must apply NEITHER mute — the whole board shows, never a partial filter.
        let board = try await adapter.loadBoard(config: .appDefault, now: Self.newerTime)
        #expect(board.neglected.count == 1)
        #expect(board.ghosted.count == 1)
    }

}

/// A triage store whose reads always throw — proves `loadBoard` degrades to the
/// unfiltered board (I4) rather than crashing or partially filtering.
private struct StowerThrowingTriageStore: StowerTriageStoring {
    private enum Failure: Error { case unavailable }

    func dismissedMessages() async throws -> [String: StowerDismissedAnchor] {
        throw Failure.unavailable
    }
    func muted() async throws -> Set<String> { throw Failure.unavailable }
    func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws {}
    func undismiss(handleKey: String) async throws {}
    func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws {}
    func mute(handleKey: String, at: Date) async throws {}
    func unmute(handleKey: String, at: Date) async throws {}
}
