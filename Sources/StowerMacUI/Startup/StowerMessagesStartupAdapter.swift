import Foundation
import StowerMessages

/// The real production `StowerStartupProviding` — the ONE file in `StowerMacUI`
/// that imports the engine.
///
/// It holds the engine's `StowerDebtBoardProvider` and translates between the
/// app-owned boundary types and the engine's: availability, config, the model
/// reason, and the seven-case `StowerMessagesError`. This is the
/// anti-corruption boundary; the exact engine→failure map is the table in the
/// FDA-onboarding plan ("Why the UI boundary is durable", item 2). Everything
/// else in `StowerMacUI` talks only to `StowerStartupProviding`.
///
/// The engine types are referenced by their **bare** names (`StowerDebtConfig`,
/// not `StowerMessages.StowerDebtConfig`): the module also exports a top-level
/// `enum StowerMessages`, so qualifying would read as a nested-type lookup and
/// fail to compile. The app-owned types keep distinct `StowerStartup*` names, so
/// there is no collision.
internal struct StowerMessagesStartupAdapter: StowerStartupProviding {
    private let engine: any StowerDebtBoardProviding

    /// The production composition: the real provider with all parameters
    /// defaulted (the judge owns its model id and prompt — no app model argument).
    internal init() {
        engine = StowerDebtBoardProvider()
    }

    /// Injects any engine conformer so the mapping table is testable without the
    /// real provider (the adapter-mapping tests pass `StowerFakeMessagesEngine`).
    internal init(engine: any StowerDebtBoardProviding) {
        self.engine = engine
    }

    internal func modelAvailability() async -> StowerStartupModelAvailability {
        mapAvailability(await engine.modelAvailability())
    }

    internal func loadDebtBoard(config: StowerStartupDebtConfig, now: Date) async throws {
        do {
            // The onboarding probe DISCARDS the returned board — it needs only
            // success-vs-throw to route. The board slice reads the board through a
            // separate seam; this method's Void signature never changes.
            _ = try await engine.loadDebtBoard(config: mapConfig(config), now: now)
        } catch let error as StowerMessagesError {
            throw mapError(error)
        }
        // Any other throw (incl. CancellationError) propagates unchanged; the
        // startup model turns an unrecognized non-cancellation throw into
        // `.unexpected` and lets `CancellationError` pass without routing.
    }

    /// The total engine→app error map (the item-2 table); exhaustive by design, so
    /// a new engine case breaks the build until it is mapped here.
    private func mapError(_ error: StowerMessagesError) -> StowerStartupFailure {
        switch error {
        case .fullDiskAccessMissing(let path): return .fullDiskAccessMissing(path: path)
        case .languageModelUnavailable(let reason): return .modelUnavailable(mapReason(reason))
        case .sourceNotFound: return .sourceMissing
        case .unreadableSource: return .unreadable
        case .invalidSnapshot, .invalidRow: return .invalidData
        case .invalidArgument: return .invalidConfig
        }
    }

    private func mapAvailability(
        _ availability: StowerModelAvailability
    ) -> StowerStartupModelAvailability {
        switch availability {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(mapReason(reason))
        }
    }

    private func mapReason(
        _ reason: StowerModelUnavailableReason
    ) -> StowerStartupModelUnavailableReason {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        case .unknown: return .unknown
        }
    }

    private func mapConfig(_ config: StowerStartupDebtConfig) -> StowerDebtConfig {
        StowerDebtConfig(
            unansweredForDays: config.unansweredForDays,
            minimumReciprocity: config.minimumReciprocity,
            ghostGateThreshold: config.ghostGateThreshold
        )
    }
}
