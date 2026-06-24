import Foundation
import StowerMessages

/// The real production `StowerStartupProviding` — one of the four engine-coupled
/// files in `StowerMacUI`.
///
/// It holds the engine's `StowerDebtBoardProvider` and translates between the
/// app-owned boundary types and the engine's via the shared `StowerMessagesMapping`
/// (availability, config, the model reason, and the seven-case
/// `StowerMessagesError`). This is the anti-corruption boundary; the exact
/// engine→failure map lives in `StowerMessagesMapping.mapError`, called by both
/// this adapter and `StowerLiveBoardDataSource`. Everything else in `StowerMacUI`
/// talks only to `StowerStartupProviding`.
internal struct StowerMessagesStartupAdapter: StowerStartupProviding {
    private let engine: any StowerDebtBoardProviding

    /// The production composition: the real provider with all parameters
    /// defaulted (the judge owns its model id and prompt — no app model argument).
    internal init() {
        engine = StowerDebtBoardProvider()
    }

    /// Injects any engine conformer so the mapping table is testable without the
    /// real provider (the adapter-mapping tests pass `StowerFakeMessagesEngine`),
    /// and so `StowerMessagesComposition` can share one provider across both
    /// adapters.
    internal init(engine: any StowerDebtBoardProviding) {
        self.engine = engine
    }

    internal func modelAvailability() async -> StowerStartupModelAvailability {
        StowerMessagesMapping.mapAvailability(await engine.modelAvailability())
    }

    internal func loadDebtBoard(config: StowerStartupDebtConfig, now: Date) async throws {
        do {
            // The onboarding probe DISCARDS the returned board — it needs only
            // success-vs-throw to route. The board slice reads the board through a
            // separate seam; this method's Void signature never changes.
            _ = try await engine.loadDebtBoard(
                config: StowerMessagesMapping.mapConfig(config),
                now: now
            )
        } catch let error as StowerMessagesError {
            throw StowerMessagesMapping.mapError(error)
        }
        // Any other throw (incl. CancellationError) propagates unchanged; the
        // startup model turns an unrecognized non-cancellation throw into
        // `.unexpected` and lets `CancellationError` pass without routing.
    }
}
