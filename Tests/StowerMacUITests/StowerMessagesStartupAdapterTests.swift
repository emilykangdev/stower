import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// Proves the real adapter applies the item-2 engine→failure mapping table.
///
/// Covers all seven `StowerMessagesError` cases (and the four model reasons), and
/// the 1:1 availability translation. The fake-driven routing tests throw app-owned
/// failures and so bypass `mapError`; only these tests exercise the real mapping.
@Suite internal struct StowerMessagesStartupAdapterTests {
    /// Loads through the adapter over a fake engine that throws `engineError`, and
    /// returns the app failure the adapter mapped it to.
    private func failure(from error: StowerMessagesError) async throws -> StowerStartupFailure {
        let adapter = StowerMessagesStartupAdapter(
            engine: StowerFakeMessagesEngine(loadError: error)
        )
        do {
            try await adapter.loadDebtBoard(config: .appDefault, now: Date())
            Issue.record("the adapter should have thrown for \(error)")
            return .unexpected
        } catch let mapped as StowerStartupFailure {
            return mapped
        }
    }

    @Test("fullDiskAccessMissing maps to .fullDiskAccessMissing, keeping the path")
    internal func mapsFullDiskAccessMissingKeepingPath() async throws {
        let path = "~/Library/Messages/chat.db"
        #expect(
            try await failure(from: .fullDiskAccessMissing(path))
                == .fullDiskAccessMissing(path: path)
        )
    }

    @Test("sourceNotFound maps to .sourceMissing, dropping the diagnostic string")
    internal func mapsSourceNotFound() async throws {
        #expect(try await failure(from: .sourceNotFound("/some/path")) == .sourceMissing)
    }

    @Test("unreadableSource maps to .unreadable, dropping the diagnostic string")
    internal func mapsUnreadableSource() async throws {
        #expect(try await failure(from: .unreadableSource("disk error")) == .unreadable)
    }

    @Test("invalidSnapshot maps to .invalidData")
    internal func mapsInvalidSnapshot() async throws {
        #expect(try await failure(from: .invalidSnapshot) == .invalidData)
    }

    @Test("invalidRow collapses into the same .invalidData screen")
    internal func mapsInvalidRow() async throws {
        #expect(try await failure(from: .invalidRow("bad row")) == .invalidData)
    }

    @Test("invalidArgument maps to .invalidConfig (an app/developer bug)")
    internal func mapsInvalidArgument() async throws {
        #expect(try await failure(from: .invalidArgument("out of range")) == .invalidConfig)
    }

    @Test(
        "languageModelUnavailable maps 1:1 per reason",
        arguments: [
            (
                StowerModelUnavailableReason.deviceNotEligible,
                StowerStartupModelUnavailableReason.deviceNotEligible
            ),
            (
                StowerModelUnavailableReason.appleIntelligenceNotEnabled,
                StowerStartupModelUnavailableReason.appleIntelligenceNotEnabled
            ),
            (
                StowerModelUnavailableReason.modelNotReady,
                StowerStartupModelUnavailableReason.modelNotReady
            ),
            (StowerModelUnavailableReason.unknown, StowerStartupModelUnavailableReason.unknown)
        ]
    )
    internal func mapsLanguageModelUnavailablePerReason(
        engineReason: StowerModelUnavailableReason,
        appReason: StowerStartupModelUnavailableReason
    ) async throws {
        let mapped = try await failure(from: .languageModelUnavailable(engineReason))
        #expect(mapped == .modelUnavailable(appReason))
    }

    @Test("modelAvailability translates .available 1:1")
    internal func mapsAvailableAvailability() async {
        let adapter = StowerMessagesStartupAdapter(
            engine: StowerFakeMessagesEngine(availability: .available)
        )
        #expect(await adapter.modelAvailability() == .available)
    }

    @Test(
        "modelAvailability translates .unavailable(reason) 1:1 per reason",
        arguments: [
            (
                StowerModelUnavailableReason.deviceNotEligible,
                StowerStartupModelUnavailableReason.deviceNotEligible
            ),
            (
                StowerModelUnavailableReason.appleIntelligenceNotEnabled,
                StowerStartupModelUnavailableReason.appleIntelligenceNotEnabled
            ),
            (
                StowerModelUnavailableReason.modelNotReady,
                StowerStartupModelUnavailableReason.modelNotReady
            ),
            (StowerModelUnavailableReason.unknown, StowerStartupModelUnavailableReason.unknown)
        ]
    )
    internal func mapsUnavailableAvailabilityPerReason(
        engineReason: StowerModelUnavailableReason,
        appReason: StowerStartupModelUnavailableReason
    ) async {
        let adapter = StowerMessagesStartupAdapter(
            engine: StowerFakeMessagesEngine(availability: .unavailable(engineReason))
        )
        #expect(await adapter.modelAvailability() == .unavailable(appReason))
    }
}
