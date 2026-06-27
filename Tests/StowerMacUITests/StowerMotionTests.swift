import SwiftUI
import Testing

@testable import StowerMacUI

/// Proves the motion tokens gate on Reduce Motion structurally: every token returns
/// `nil` when motion is reduced (so the consuming `.animation`/`withAnimation` becomes an
/// instant state change) and a real curve otherwise.
///
/// This guarantees the *token* degrades; it does not prove every view reads
/// `reduceMotion` — the precheck no-raw-animation guard plus `swift-signal-review` cover
/// that the views route through these tokens at all.
@Suite internal struct StowerMotionTests {
    @Test("every motion token is nil under Reduce Motion")
    internal func tokensAreNilUnderReduceMotion() {
        #expect(StowerMotion.removal(true) == nil)
        #expect(StowerMotion.composer(true) == nil)
        #expect(StowerMotion.tabSwitch(true) == nil)
        #expect(StowerMotion.crossFade(true) == nil)
        #expect(StowerMotion.press(true) == nil)
    }

    @Test("every motion token carries a curve when motion is allowed")
    internal func tokensAnimateWhenMotionAllowed() {
        #expect(StowerMotion.removal(false) != nil)
        #expect(StowerMotion.composer(false) != nil)
        #expect(StowerMotion.tabSwitch(false) != nil)
        #expect(StowerMotion.crossFade(false) != nil)
        #expect(StowerMotion.press(false) != nil)
    }
}
