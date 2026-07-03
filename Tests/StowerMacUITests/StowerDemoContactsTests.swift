import StowerMessages
import Testing

@testable import StowerMacUI

/// The demo fake-names table resolves through the real `StowerContactsResolver`
/// normalization — proving the demo handle scheme stays in lockstep with
/// `Scripts/generate-demo-db.py` (`+1415555<0100+i>`, 30 threads) so demo mode
/// shows names, not raw handles.
@Suite internal struct StowerDemoContactsTests {
    @Test("there is one demo contact per demo thread")
    internal func hasOnePerThread() {
        #expect(StowerDemoContacts.mapping.count == 30)
    }

    @Test("the first and last demo handles resolve to their names")
    internal func endpointsResolve() {
        let resolver = StowerContactsResolver(mapping: StowerDemoContacts.mapping)
        #expect(resolver.displayName(for: "+14155550100") == "Sarah Chen")
        #expect(resolver.displayName(for: "+14155550129") == "Maya Anderson")
    }

    @Test("an unmapped handle falls back to the raw handle")
    internal func unmappedFallsBack() {
        let resolver = StowerContactsResolver(mapping: StowerDemoContacts.mapping)
        #expect(resolver.displayName(for: "+14155559999") == "+14155559999")
    }
}
