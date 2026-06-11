import Foundation

internal enum StowerPhoneNormalizer {
    internal static func emailKey(for value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("@") ? "email:\(normalized)" : nil
    }

    internal static func exactPhoneKey(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else {
            return nil
        }
        let digits = phoneDigits(in: trimmed)
        return digits.isEmpty ? nil : "e164:\(digits)"
    }

    internal static func suffixPhoneKey(for value: String) -> String? {
        let digits = phoneDigits(in: value)
        guard digits.count >= 10 else {
            return nil
        }
        return "phone10:\(digits.suffix(10))"
    }

    private static func phoneDigits(in value: String) -> String {
        String(value.unicodeScalars.filter(CharacterSet.decimalDigits.contains))
    }
}
