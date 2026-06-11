import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerAttributedBodyDecoder")
internal struct StowerAttributedBodyDecoderTests {
    @Test("decodes a runtime-archived attributed string without metadata filtering")
    internal func decodesArchivedString() throws {
        let body = "NS Attribute café 🎉"
        let attributed = NSMutableAttributedString(string: body)
        attributed.addAttribute(
            NSAttributedString.Key("FixtureAttribute"),
            value: "fixture" as NSString,
            range: NSRange(location: 0, length: 2)
        )
        let data = try archive(attributed)

        #expect(try StowerAttributedBodyDecoder.decode(data) == body)
    }

    @Test("strips replacement sentinels")
    internal func stripsSentinels() throws {
        let attributed = NSAttributedString(string: "before\u{FFFC}\u{FFFD}after")
        let data = try archive(attributed)

        #expect(try StowerAttributedBodyDecoder.decode(data) == "beforeafter")
    }

    @Test("returns nil for an empty archived string")
    internal func emptyString() throws {
        let data = try archive(NSAttributedString(string: ""))

        #expect(try StowerAttributedBodyDecoder.decode(data) == nil)
    }

    @Test("throws for malformed data")
    internal func malformedData() {
        #expect(throws: (any Error).self) {
            try StowerAttributedBodyDecoder.decode(Data([0x01, 0x02]))
        }
    }

    private func archive(_ value: Any) throws -> Data {
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        guard let archiver = NSClassFromString("NSArchiver") as? NSObject.Type,
            let result = archiver.perform(selector, with: value),
            let data = result.takeUnretainedValue() as? Data
        else {
            throw ArchiveError.failed
        }
        return data
    }
}

private enum ArchiveError: Error {
    case failed
}
