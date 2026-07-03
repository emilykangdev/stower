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

    @Test internal func trialStartedSignalName() {
        #expect(StowerAnalyticsEvent.trialStarted.signalName == "trial_started")
    }

    @Test internal func paywallReachedSignalName() {
        #expect(
            StowerAnalyticsEvent.paywallReached(error: .couldNotReach).signalName
                == "paywall_reached"
        )
    }

    @Test internal func checkoutOpenedSignalName() {
        #expect(StowerAnalyticsEvent.checkoutOpened.signalName == "checkout_opened")
    }

    @Test internal func activatedSignalName() {
        #expect(StowerAnalyticsEvent.activated.signalName == "activated")
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

    @Test internal func feedbackOpenedSignalName() {
        #expect(
            StowerAnalyticsEvent.feedbackOpened(licenseStatus: "trial").signalName
                == "feedback_opened"
        )
    }

    @Test internal func feedbackSentSignalName() {
        #expect(
            StowerAnalyticsEvent.feedbackSent(licenseStatus: "paid").signalName == "feedback_sent"
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

    @Test internal func paywallReachedNoErrorHasNoParams() {
        #expect(StowerAnalyticsEvent.paywallReached(error: nil).parameters.isEmpty)
    }

    @Test internal func paywallReachedInvalidToken() {
        #expect(
            StowerAnalyticsEvent.paywallReached(error: .invalid).parameters["error"] == "invalid"
        )
    }

    @Test internal func paywallReachedCouldNotReachToken() {
        #expect(
            StowerAnalyticsEvent.paywallReached(error: .couldNotReach).parameters["error"]
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

    @Test(
        "I-AnalyticsNoPII: feedback events carry only license_status, no message/email/instanceID"
    )
    internal func feedbackEventsParamsArePIISafe() {
        for event: StowerAnalyticsEvent in [
            .feedbackOpened(licenseStatus: "trial"),
            .feedbackSent(licenseStatus: "paid")
        ] {
            let params = event.parameters
            #expect(Set(params.keys) == ["license_status"])
            #expect(params.count == 1)
        }
        #expect(
            StowerAnalyticsEvent.feedbackSent(licenseStatus: "paid").parameters["license_status"]
                == "paid"
        )
    }

    @Test internal func emptyParamEventsHaveNoParams() {
        for event: StowerAnalyticsEvent in [
            .appLaunched, .sessionEnded, .fdaPermissionRequested, .boardReached, .trialStarted,
            .checkoutOpened, .activated
        ] {
            #expect(event.parameters.isEmpty, "Expected \(event.signalName) to have no parameters")
        }
    }
}
