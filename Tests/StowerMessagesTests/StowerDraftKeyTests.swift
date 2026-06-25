import Foundation
import Testing

@testable import StowerMessages

/// `StowerDraftKey.derive` is pure and deterministic (I-KeyDeterministic): a
/// `+`-variant of one number collapses to a single `e164:<digits>` key (no `+`),
/// an email lowercases, a non-`+` handle falls back to `raw:`, and the lossy
/// `phone10:` suffix form is never produced.
@Suite("StowerDraftKey")
internal struct StowerDraftKeyTests {
    @Test("plus-variants of one number derive a single e164 key with no plus")
    internal func phoneVariantsConverge() {
        let spaced = StowerDraftKey.derive(forHandle: "+1 (555) 123-4567")
        let bare = StowerDraftKey.derive(forHandle: "+15551234567")
        #expect(spaced == "e164:15551234567")
        #expect(bare == "e164:15551234567")
        #expect(spaced == bare)
    }

    @Test("an email lowercases under the email prefix")
    internal func emailLowercases() {
        #expect(StowerDraftKey.derive(forHandle: "Foo@X.com") == "email:foo@x.com")
    }

    @Test("a non-plus handle falls back to raw, never phone10")
    internal func nonPlusFallsBackToRaw() {
        // A bare 10-digit number has no '+', so it is NOT e164 and must not become a
        // lossy phone10 suffix key — it stays raw.
        #expect(StowerDraftKey.derive(forHandle: "5551234567") == "raw:5551234567")
        #expect(StowerDraftKey.derive(forHandle: "chat99") == "raw:chat99")
    }

    @Test("derivation never emits a phone10 suffix key")
    internal func neverPhone10() {
        let keys = ["+1 (555) 123-4567", "+15551234567", "Foo@X.com", "5551234567", "chat99"]
            .map(StowerDraftKey.derive(forHandle:))
        #expect(keys.allSatisfy { !$0.hasPrefix("phone10:") })
    }

    @Test("a raw fallback trims surrounding whitespace")
    internal func rawTrims() {
        #expect(StowerDraftKey.derive(forHandle: "  chat99  ") == "raw:chat99")
    }
}
