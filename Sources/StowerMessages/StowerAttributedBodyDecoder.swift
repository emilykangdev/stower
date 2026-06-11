import Foundation
import TypedStream

internal enum StowerAttributedBodyDecoder {
    internal static func decode(_ data: Data) throws -> String? {
        let values = try TypedStreamDecoder.decode(data)
        guard let body = values.lazy.compactMap(messageString).first else {
            return nil
        }
        let cleaned =
            body
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func messageString(from value: Archivable) -> String? {
        guard case .object(let classInfo, let objects) = value,
            classInfo.name == "NSString" || classInfo.name == "NSMutableString",
            let first = objects.first,
            case .string(let text) = first
        else {
            return nil
        }
        return text
    }
}
