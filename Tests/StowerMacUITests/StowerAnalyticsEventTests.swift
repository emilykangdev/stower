import Foundation
import Testing

@testable import StowerMacUI

/// Tests the typed event enum: signal names, PII-safe parameter contract,
/// and per-case parameter assertions.
@Suite internal struct StowerAnalyticsEventTests {

    // MARK: — Signal names

    @Test internal func appLaunchedSignalName() {
        #expect(StowerAnalyticsEvent.appLaunched.signalName == "app_launched")
    }

    @Test internal func sessionEndedSignalName() {
        #expect(StowerAnalyticsEvent.sessionEnded.signalName == "session_ended")
    }

    @Test internal func hardwareCheckedSignalName() {
        #expect(
            StowerAnalyticsEvent.hardwareChecked(supported: true, reason: nil).signalName
                == "hardware_checked"
        )
    }

    @Test internal func licenseGateReachedSignalName() {
        #expect(
            StowerAnalyticsEvent.licenseGateReached(context: .couldNotReach).signalName
                == "license_gate_reached"
        )
    }

    @Test internal func fdaRequestedSignalName() {
        #expect(
            StowerAnalyticsEvent.fdaPermissionRequested.signalName == "fda_permission_requested"
        )
    }

    @Test internal func fdaResolvedSignalName() {
        #expect(
            StowerAnalyticsEvent.fdaPermissionResolved(granted: true).signalName
                == "fda_permission_resolved"
        )
    }

    @Test internal func boardReachedSignalName() {
        #expect(StowerAnalyticsEvent.boardReached.signalName == "board_reached")
    }

    @Test internal func boardItemClickedSignalName() {
        #expect(
            StowerAnalyticsEvent.boardItemClicked(itemType: "message_row_dismiss").signalName
                == "board_item_clicked"
        )
    }

    @Test internal func featureUsedSignalName() {
        #expect(
            StowerAnalyticsEvent.featureUsed(feature: "buy", surface: "trial_badge").signalName
                == "feature_used"
        )
    }

    // MARK: — Parameter contracts (PII-safe: no raw contact/message/path)

    @Test internal func hardwareCheckedSupportedParams() {
        let params = StowerAnalyticsEvent.hardwareChecked(supported: true, reason: nil).parameters
        #expect(params["supported"] == "true")
        #expect(params["reason"] == nil)
    }

    @Test internal func hardwareCheckedUnsupportedParams() {
        let params = StowerAnalyticsEvent.hardwareChecked(
            supported: false,
            reason: "deviceNotEligible"
        ).parameters
        #expect(params["supported"] == "false")
        #expect(params["reason"] == "deviceNotEligible")
    }

    @Test internal func licenseGateContextTrialExpired() {
        let params = StowerAnalyticsEvent.licenseGateReached(
            context: .trialExpired(licenseID: "ignored-should-not-appear")
        ).parameters
        // licenseID must NOT appear in parameters — only the coarse token.
        #expect(params["context"] == "trial_expired")
        #expect(params.values.contains(where: { $0.contains("ignored") }) == false)
    }

    @Test internal func licenseGateContextUpgradeRequired() {
        let params = StowerAnalyticsEvent.licenseGateReached(
            context: .upgradeRequired(licenseID: "secret-id")
        ).parameters
        #expect(params["context"] == "upgrade_required")
        #expect(params.values.contains(where: { $0.contains("secret") }) == false)
    }

    @Test internal func licenseGateContextConnectOnce() {
        #expect(
            StowerAnalyticsEvent.licenseGateReached(context: .connectOnce).parameters["context"]
                == "connect_once"
        )
    }

    @Test internal func licenseGateContextCouldNotReach() {
        #expect(
            StowerAnalyticsEvent.licenseGateReached(context: .couldNotReach).parameters["context"]
                == "could_not_reach"
        )
    }

    @Test internal func fdaResolvedGrantedParams() {
        #expect(
            StowerAnalyticsEvent.fdaPermissionResolved(granted: true).parameters["granted"]
                == "true"
        )
        #expect(
            StowerAnalyticsEvent.fdaPermissionResolved(granted: false).parameters["granted"]
                == "false"
        )
    }

    @Test internal func boardItemClickedParams() {
        let params = StowerAnalyticsEvent.boardItemClicked(itemType: "message_row_dismiss")
            .parameters
        #expect(params["item_type"] == "message_row_dismiss")
        // Exactly one parameter; no raw content.
        #expect(params.count == 1)
    }

    @Test internal func featureUsedParams() {
        let params = StowerAnalyticsEvent.featureUsed(feature: "buy", surface: "trial_badge")
            .parameters
        #expect(params["feature"] == "buy")
        #expect(params["surface"] == "trial_badge")
    }

    @Test internal func emptyParamEventsHaveNoParams() {
        for event: StowerAnalyticsEvent in [
            .appLaunched, .sessionEnded, .fdaPermissionRequested, .boardReached
        ] {
            #expect(event.parameters.isEmpty, "Expected \(event.signalName) to have no parameters")
        }
    }
}
