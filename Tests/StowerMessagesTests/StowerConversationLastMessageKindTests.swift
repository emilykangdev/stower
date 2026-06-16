import Testing

@testable import StowerMessages

@Suite("StowerConversationLastMessageKind")
internal struct StowerConversationLastMessageKindTests {
    @Test("raw values are the stable persisted cache-key tokens")
    internal func rawValuesAreStable() {
        // The case token is folded into the persisted verdict-cache key (inputHash).
        // These raw values must equal the historical `String(describing:)` output so
        // existing cache entries stay valid, and must never drift silently — a case
        // rename that changes one is a cache-wide miss that re-judges every thread.
        #expect(StowerConversationLastMessageKind.text.rawValue == "text")
        #expect(StowerConversationLastMessageKind.link.rawValue == "link")
        #expect(StowerConversationLastMessageKind.attachment.rawValue == "attachment")
        #expect(StowerConversationLastMessageKind.app.rawValue == "app")
        #expect(StowerConversationLastMessageKind.other.rawValue == "other")
    }
}
