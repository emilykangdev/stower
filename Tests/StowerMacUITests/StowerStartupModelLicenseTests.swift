import Foundation
import Testing

@testable import StowerMacUI

/// The model-side licensing wiring: the gate runs only after availability, each
/// `StowerLicenseState` routes to the right state, activation persists only
/// under the generation guard (I4), and a foreground re-check refreshes an
/// on-board license without a full restart.
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

    @Test("a licensed state proceeds into the board flow")
    internal func licensedStateProceeds() async {
        let gate = StowerFakeLicenseGate(states: [.licensed])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
        #expect(gate.stateCallCount == 1)
    }

    @Test("an active trial state proceeds into the board flow")
    internal func trialStateProceeds() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = StowerFakeLicenseGate(states: [.trial(expiry: expiry)])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
    }

    @Test("a licensed state still routes an FDA-missing load to the FDA screen")
    internal func licensedStateRoutesFDAFailure() async {
        let path = "~/Library/Messages/chat.db"
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.failure(.fullDiskAccessMissing(path: path))]
        )
        let gate = StowerFakeLicenseGate(states: [.licensed])
        let model = makeModel(provider: provider, licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsFullDiskAccess(path: path))
    }

    @Test("an expired state routes to needsLicense(nil) — the paywall/key-entry screen")
    internal func expiredRoutesToPaywall() async {
        let gate = StowerFakeLicenseGate(states: [.expired])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(nil))
    }

    @Test("B-I11: the license gate is never asked when the model is unavailable")
    internal func unavailableModelNeverChecksLicense() async {
        let gate = StowerFakeLicenseGate(states: [.expired])
        let provider = StowerFakeStartupProvider(availability: .unavailable(.deviceNotEligible))
        let model = makeModel(provider: provider, licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .modelUnavailable(.deviceNotEligible))
        #expect(gate.stateCallCount == 0)
    }

    @Test("foreground re-check: a still-licensed state stays on the board")
    internal func foregroundRecheckLicensedStaysOnBoard() async {
        let gate = StowerFakeLicenseGate(states: [.licensed, .licensed])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)

        await model.refreshLicenseIfOnBoard()
        #expect(model.state == .connectedPreparingBoard)
        #expect(gate.stateCallCount == 2)  // startup + the foreground re-check
    }

    @Test("foreground re-check: a still-active trial stays on the board")
    internal func foregroundRecheckTrialStaysOnBoard() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = StowerFakeLicenseGate(
            states: [.trial(expiry: expiry), .trial(expiry: expiry)]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)

        await model.refreshLicenseIfOnBoard()
        #expect(model.state == .connectedPreparingBoard)
    }

    @Test("foreground re-check: a now-expired trial routes to the paywall")
    internal func foregroundRecheckExpiredRoutesToPaywall() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = StowerFakeLicenseGate(states: [.trial(expiry: expiry), .expired])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)

        await model.refreshLicenseIfOnBoard()
        #expect(model.state == .needsLicense(nil))
    }

    @Test("foreground re-check is a no-op when not on the board")
    internal func foregroundRecheckNoOpOffBoard() async {
        let gate = StowerFakeLicenseGate(states: [.expired])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        // No start() → state is .checkingModel, not on the board.
        await model.refreshLicenseIfOnBoard()
        #expect(gate.stateCallCount == 0)
        #expect(model.state == .checkingModel)
    }

    @Test("the model passes its clock's now into licenseState")
    internal func passesClockNow() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = StowerFakeLicenseGate(states: [.licensed])
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

    // MARK: - Activation (I4)

    @Test("a successful activate persists the key and reruns startup into the board")
    internal func activateSuccessPersistsAndReenters() async {
        let gate = StowerFakeLicenseGate(
            states: [.expired, .licensed],
            activationResult: .activated(instanceID: "inst-1")
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(nil))

        await model.activate(key: "KEY")
        await model.activeRun?.value

        #expect(gate.persistCalls.map(\.key) == ["KEY"])
        #expect(gate.persistCalls.map(\.instanceID) == ["inst-1"])
        #expect(model.state == .connectedPreparingBoard)
    }

    @Test("an invalid activation commits needsLicense(.invalid)")
    internal func activateInvalidCommitsError() async {
        let gate = StowerFakeLicenseGate(states: [.expired], activationResult: .invalid)
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value

        await model.activate(key: "KEY")

        #expect(model.state == .needsLicense(.invalid))
        #expect(gate.persistCalls.isEmpty)
    }

    @Test("a couldNotReach activation commits needsLicense(.couldNotReach) and never persists")
    internal func activateCouldNotReachCommitsError() async {
        let gate = StowerFakeLicenseGate(states: [.expired], activationResult: .couldNotReach)
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value

        await model.activate(key: "KEY")

        #expect(model.state == .needsLicense(.couldNotReach))
        #expect(gate.persistCalls.isEmpty)
    }

    @Test("I4: cancel() during an in-flight activate drops the superseded persist")
    internal func supersededActivationDoesNotPersist() async {
        let gate = StowerFakeLicenseGate(
            states: [.expired],
            activationResult: .activated(instanceID: "inst-1"),
            blocksActivation: true
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value

        let activateTask = Task { await model.activate(key: "KEY") }
        while gate.activationCallCountValue < 1 {
            await Task.yield()
        }
        // cancel() bumps the generation while activate(key:) is still blocked
        // inside licenseGate.activate — the generation guard must then drop
        // the late persist.
        model.cancel()
        gate.releaseActivation()
        await activateTask.value

        #expect(gate.persistCalls.isEmpty)
    }
}
