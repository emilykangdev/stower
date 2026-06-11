import Testing

@testable import StowerMessages

@Suite("StowerContactsResolver")
internal struct StowerContactsResolverTests {
    @Test("normalizes email, E.164, and formatted national phone handles")
    internal func matchingMatrix() {
        let mapping = [" Person@Example.com ": "Email Person", "+1 (415) 555-0100": "Phone Person"]
        let resolver = StowerContactsResolver(mapping: mapping)

        #expect(resolver.displayName(for: "person@example.com") == "Email Person")
        #expect(resolver.displayName(for: "+14155550100") == "Phone Person")
        #expect(resolver.displayName(for: "(415) 555-0100") == "Phone Person")
    }

    @Test("exact E.164 wins over an ambiguous suffix")
    internal func exactWins() {
        let mapping = ["+14155550100": "US Person", "+9914155550100": "Other Person"]
        let resolver = StowerContactsResolver(mapping: mapping)

        #expect(resolver.displayName(for: "+14155550100") == "US Person")
        #expect(resolver.displayName(for: "4155550100") == "4155550100")
    }

    @Test("ambiguous suffix matching is independent of enumeration order")
    internal func ambiguousSuffixIsDeterministic() {
        let entries = [("+14155550100", "First"), ("+9914155550100", "Second")]
        let forward = StowerContactsResolver(
            mapping: Dictionary(uniqueKeysWithValues: entries)
        )
        let reversed = StowerContactsResolver(
            mapping: Dictionary(uniqueKeysWithValues: entries.reversed())
        )

        #expect(forward.displayName(for: "4155550100") == "4155550100")
        #expect(reversed.displayName(for: "4155550100") == "4155550100")
    }

    @Test("an empty resolver degrades to the raw handle")
    internal func rawHandleFallback() {
        let resolver = StowerContactsResolver()

        #expect(resolver.displayName(for: "+14155550100") == "+14155550100")
    }
}
