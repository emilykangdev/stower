import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The board adapter crosses the seam app-owned.
///
/// A `StowerMessagesError` from the engine is caught and rethrown as a
/// `StowerStartupFailure`, and a clean load maps into an app-owned
/// `StowerBoardModel`. Mirrors `StowerMessagesStartupAdapterTests` over
/// `StowerFakeMessagesEngine`.
@Suite internal struct StowerLiveBoardDataSourceTests {
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
        let adapter = StowerLiveBoardDataSource(engine: StowerFakeMessagesEngine())
        let board = try await adapter.loadBoard(config: .appDefault, now: Date())
        #expect(board.isEmpty)
    }
}
