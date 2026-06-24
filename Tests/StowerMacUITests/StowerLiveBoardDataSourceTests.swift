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

    private static func item(chatID: String) -> StowerDebtItem {
        StowerDebtItem(
            chatID: chatID,
            chatTitle: "Alex",
            counterpart: handle,
            counterpartHandle: handle,
            lastMessageKind: .text,
            lastMessageText: "hello",
            lastMessageTimestamp: Date(timeIntervalSince1970: 1_000_000),
            deepLink: nil,
            replyExpectationConfidence: 0.8
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
}
