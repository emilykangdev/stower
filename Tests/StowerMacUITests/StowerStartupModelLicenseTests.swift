import Foundation
import Testing

@testable import StowerMacUI

/// The licensing ordering, activation, persistence, and re-entrancy invariants
/// (I1–I8, I11, I14).
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

    @Test("I1: a stored license proceeds without any activate network call")
    internal func storedLicenseSkipsActivation() async {
        let gate = StowerFakeLicenseGate(hasLicense: true)
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
        #expect(gate.activateCallCount == 0)
    }

    @Test("I2: no stored license routes to the entry screen after the model check")
    internal func noLicenseRoutesToEntry() async {
        let gate = StowerFakeLicenseGate(hasLicense: false)
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .needsLicense(nil))
        #expect(gate.activateCallCount == 0)
    }

    @Test("I3/I11: a valid activation persists the trimmed key and routes to the board")
    internal func activationPersistsTrimmedKeyAndRoutes() async {
        let gate = StowerFakeLicenseGate(
            hasLicense: false,
            activate: [.outcome(.activated(instanceID: "inst-1"))]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("  KEY  ")
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
        #expect(gate.persistedLicenses == [StowerStoredLicense(key: "KEY", instanceID: "inst-1")])
    }

    @Test("I3: a valid activation still routes an FDA-missing load to the FDA screen")
    internal func activationRoutesFDAFailure() async {
        let path = "~/Library/Messages/chat.db"
        let provider = StowerFakeStartupProvider(
            loadBehaviors: [.failure(.fullDiskAccessMissing(path: path))]
        )
        let gate = StowerFakeLicenseGate(
            hasLicense: false,
            activate: [.outcome(.activated(instanceID: "inst"))]
        )
        let model = makeModel(provider: provider, licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("KEY")
        await model.activeRun?.value
        #expect(model.state == .needsFullDiskAccess(path: path))
    }

    @Test("I4: an invalid activation persists nothing and shows the invalid error")
    internal func invalidActivationShowsError() async {
        let gate = StowerFakeLicenseGate(hasLicense: false, activate: [.outcome(.invalid)])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("KEY")
        await model.activeRun?.value
        #expect(model.state == .needsLicense(.invalid))
        #expect(gate.persistedLicenses.isEmpty)
    }

    @Test("I5: a couldNotReach activation persists nothing and shows the retry error")
    internal func couldNotReachActivationShowsError() async {
        let gate = StowerFakeLicenseGate(hasLicense: false, activate: [.outcome(.couldNotReach)])
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("KEY")
        await model.activeRun?.value
        #expect(model.state == .needsLicense(.couldNotReach))
        #expect(gate.persistedLicenses.isEmpty)
    }

    @Test("I6: a superseded activation neither persists nor commits")
    internal func supersededActivationDoesNotPersist() async {
        let gate = StowerFakeLicenseGate(
            hasLicense: false,
            activate: [.blockUntilReleased(.activated(instanceID: "inst")), .outcome(.invalid)]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("A")
        while gate.activateCallCount < 1 {
            await Task.yield()
        }
        let runA = model.activeRun
        model.submitLicense("B")
        await model.activeRun?.value
        gate.release()
        await runA?.value
        #expect(model.state == .needsLicense(.invalid))
        #expect(gate.persistedLicenses.isEmpty)
    }

    @Test("I7: the license gate is never asked when the model is unavailable")
    internal func unavailableModelNeverActivates() async {
        let gate = StowerFakeLicenseGate(hasLicense: false)
        let provider = StowerFakeStartupProvider(availability: .unavailable(.deviceNotEligible))
        let model = makeModel(provider: provider, licenseGate: gate)
        model.start()
        await model.activeRun?.value
        #expect(model.state == .modelUnavailable(.deviceNotEligible))
        #expect(gate.activateCallCount == 0)
    }

    @Test("I8: an overlapping submit cancels the in-flight activation without routing to .failed")
    internal func overlappingSubmitDiscardsStaleActivation() async {
        let gate = StowerFakeLicenseGate(
            hasLicense: false,
            activate: [.blockUntilCancelled, .outcome(.activated(instanceID: "inst"))]
        )
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("A")
        while gate.activateCallCount < 1 {
            await Task.yield()
        }
        model.submitLicense("B")
        await model.activeRun?.value
        #expect(model.state == .connectedPreparingBoard)
    }

    @Test("I11: an all-whitespace key does not submit")
    internal func whitespaceKeyDoesNotSubmit() async {
        let gate = StowerFakeLicenseGate(hasLicense: false)
        let model = makeModel(provider: StowerFakeStartupProvider(), licenseGate: gate)
        model.start()
        await model.activeRun?.value
        model.submitLicense("   \n")
        #expect(gate.activateCallCount == 0)
        #expect(model.state == .needsLicense(nil))
    }

    @Test("I14: an activation commits .checkingLicense before resolving")
    internal func activationShowsCheckingLicense() async {
        let recorder = StowerStateRecorder()
        let gate = StowerFakeLicenseGate(hasLicense: false, activate: [.outcome(.invalid)])
        let model = makeModel(
            provider: StowerFakeStartupProvider(),
            licenseGate: gate,
            onCommit: { recorder.append($0) }
        )
        model.start()
        await model.activeRun?.value
        model.submitLicense("KEY")
        await model.activeRun?.value
        #expect(recorder.states.contains(.checkingLicense))
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
