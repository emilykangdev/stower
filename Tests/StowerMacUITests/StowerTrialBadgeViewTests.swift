import Foundation
import Testing

@testable import StowerMacUI

/// The trial badge's pure label formatting (I-H12a).
///
/// View visibility (the board overlay × gear-menu × dismissal matrix) is NOT tested
/// here — that needs ViewInspector, which this repo forbids; it's a manual
/// Release-checklist item.
@Suite internal struct StowerTrialBadgeViewTests {
    @Test("endLabel renders the canonical prefix + a medium-style date")
    internal func endLabelFormatsDate() {
        let expiry = Date(timeIntervalSince1970: 1_785_000_000)
        // Compute the expected suffix with an IDENTICALLY-configured formatter
        // (.medium/.none, process default locale + time zone) so the assertion is
        // locale/TZ-independent — never a hard-coded "Jul 28, 2026".
        let reference = DateFormatter()
        reference.dateStyle = .medium
        reference.timeStyle = .none
        #expect(
            StowerTrialBadgeView.endLabel(for: expiry)
                == "Free trial · ends \(reference.string(from: expiry))"
        )
    }
}
