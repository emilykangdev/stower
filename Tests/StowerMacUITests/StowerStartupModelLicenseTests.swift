import Foundation
import Testing

@testable import StowerMacUI

/// The model-side licensing wiring: the gate runs only after availability
/// (B-I11), the `.checkingLicense` reason is picked from `hasLease()` (B-I13), and
/// each `StowerLicenseStatus` routes to the right state (B-I4/B-I7 + the rest).
///
/// Split from `StowerStartupModelTests` to keep each suite within the type-body
/// length budget. Same `StowerFakeStartupProvider` + `StowerFakeLicenseGate`
/// doubles — no engine, no network, and a no-op minimum-display sleep.
@Suite @MainActor internal struct StowerStartupModelLicenseTests {
    /// Builds a model with the minimum-display delay disabled.
    private func makeModel(
        provider: StowerFakeStartupProvider,
        licenseGate: any StowerLicenseGating,
        onCommit: (@MainActor @Sendable (StowerStartupState) -> Void)? = nil
    ) -> StowerStartupModel {
        StowerStartupModel(
            provider: provider,
            licenseGate: licenseGate,
            sleep: { _ in },
            onCommit: onCommit
        )
    }

    @Test("a valid status proceeds into the board flow")
    internal func validStatusProceeds() async {
        let gate = StowerFakeLicenseGate(hasLease: true, statuses: [.status(.valid)])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
        #expect(gate.statusCallCount == 1)
    }

    @Test("a valid status still routes an FDA-missing load to the FDA screen")
    internal func validStatusRoutesFDAFailure() async {
        let path = "~/Library/Messages/chat.db"
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.failure(.fullDiskAccessMissing(path: path))]
        )
        let gate = StowerFakeLicenseGate(hasLease: true, statuses: [.status(.valid)])
        let model = makeModel(provider: provider, licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsFullDiskAccess(path: path))
    }

    @Test("B-I4: a trialExpired status routes to needsLicense(.trialExpired) carrying the id")
    internal func trialExpiredRoutesToEntry() async {
        let gate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.trialExpired(licenseID: "lic-42"))]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(.trialExpired(licenseID: "lic-42")))
    }

    @Test("B-I7: a wrongVersion status routes to needsLicense(.upgradeRequired) carrying the id")
    internal func wrongVersionRoutesToUpgrade() async {
        let gate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.wrongVersion(licenseID: "lic-7"))]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(.upgradeRequired(licenseID: "lic-7")))
    }

    @Test("a couldNotReach status routes to needsLicense(.couldNotReach)")
    internal func couldNotReachRoutesToRetry() async {
        let gate = StowerFakeLicenseGate(hasLease: true, statuses: [.status(.couldNotReach)])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(.couldNotReach))
    }

    @Test("B-I8 (model): a needsTrialOnline status routes to needsLicense(.connectOnce)")
    internal func needsTrialOnlineRoutesToConnectOnce() async {
        let gate = StowerFakeLicenseGate(hasLease: false, statuses: [.status(.needsTrialOnline)])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(.connectOnce))
    }

    @Test("B-I11: the license gate is never asked when the model is unavailable")
    internal func unavailableModelNeverChecksLicense() async {
        let gate = StowerFakeLicenseGate(hasLease: false)
        let provider = StowerFakeStartupProvider(availability: .unavailable(.deviceNotEligible))
        let model = makeModel(provider: provider, licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .modelUnavailable(.deviceNotEligible))
        #expect(gate.statusCallCount == 0)
    }

    @Test("B-I13: a warm lease commits .checkingLicense(.revalidating)")
    internal func warmLeaseShowsRevalidating() async {
        let recorder = StowerStateRecorder()
        let gate = StowerFakeLicenseGate(hasLease: true, statuses: [.status(.valid)])
        let model = makeModel(
            provider: StowerFakeStartupProvider(),
            licenseGate: gate,
            onCommit: { recorder.append($0) }
        )
        model.start()
        await model.activeRun?.value
        #expect(recorder.states.contains(.checkingLicense(.revalidating)))
        #expect(!recorder.states.contains(.checkingLicense(.startingTrial)))
    }

    @Test("B-I13: first run (no lease) commits .checkingLicense(.startingTrial)")
    internal func firstRunShowsStartingTrial() async {
        let recorder = StowerStateRecorder()
        let gate = StowerFakeLicenseGate(hasLease: false, statuses: [.status(.valid)])
        let model = makeModel(
            provider: StowerFakeStartupProvider(),
            licenseGate: gate,
            onCommit: { recorder.append($0) }
        )
        model.start()
        await model.activeRun?.value
        #expect(recorder.states.contains(.checkingLicense(.startingTrial)))
        #expect(!recorder.states.contains(.checkingLicense(.revalidating)))
    }

    @Test("the model passes its clock's now into currentStatus")
    internal func passesClockNow() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = StowerFakeLicenseGate(hasLease: true, statuses: [.status(.valid)])
        let model = StowerStartupModel(
            provider: StowerFakeStartupProvider(),
            licenseGate: gate,
            clock: { fixedNow },
            sleep: { _ in }
        )
        model.start()
        await model.activeRun?.value
        #expect(gate.recordedNowValues == [fixedNow])
    }

    @Test("a status check superseded by cancel() never commits its result")
    internal func supersededStatusDoesNotCommit() async {
        let gate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.blockUntilReleased(.trialExpired(licenseID: "lic-1"))]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        while gate.statusCallCount < 1 {
            await Task.yield()
        }
        let run = model.activeRun
        // A cancel() bumps the generation while currentStatus is blocked; the
        // generation guard must then drop the late commit.
        model.cancel()
        gate.release()
        await run?.value
        #expect(model.state != .needsLicense(.trialExpired(licenseID: "lic-1")))
    }

    // MARK: - Dismissal isolation (I3)

    @Test("dismissed badge does NOT suppress .trialExpired routing (I3)")
    internal func dismissedBadgeDoesNotSuppressTrialExpired() async {
        // Even when the badge has been dismissed (isDismissed == true in the
        // presentation layer), the warranted .trialExpired license status must still
        // route to the entry screen. The startup model is completely unaware of
        // the dismissal flag; only the view layer reads it.
        let gate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.trialExpired(licenseID: "lic-42"))],
            trialBadge: StowerTrialBadge(
                licenseID: "lic-42",
                expiry: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        // The model routes to the paywall — no badge suppression here.
        #expect(model.state == .needsLicense(.trialExpired(licenseID: "lic-42")))
    }

    @Test("trialBadge() on the model delegates to the gate and carries the decoded expiry")
    internal func modelTrialBadgeDelegatesToGate() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let expectedBadge = StowerTrialBadge(licenseID: "lic-1", expiry: expiry)
        let gate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.valid)],
            trialBadge: expectedBadge
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        // The read-through is available immediately, before start() (pure local read).
        #expect(model.trialBadge() == expectedBadge)
    }

    @Test("trialBadge() is nil when the gate returns nil (paid license)")
    internal func modelTrialBadgeNilForPaid() async {
        let gate = StowerFakeLicenseGate(
            hasLease: true,
            statuses: [.status(.valid)],
            trialBadge: nil
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        #expect(model.trialBadge() == nil)
    }
}

/// Records every committed state for the `onCommit` transition tests.
private final class StowerStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StowerStartupState] = []

    func append(_ state: StowerStartupState) {
        lock.withLock { recorded.append(state) }
    }

    var states: [StowerStartupState] {
        lock.withLock { recorded }
    }
}
