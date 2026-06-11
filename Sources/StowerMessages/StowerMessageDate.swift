import Foundation

internal enum StowerMessageDate {
    internal static let nanosecondsThreshold: Int64 = 1_000_000_000_000

    internal static func date(from rawValue: Int64) -> Date? {
        guard rawValue != 0 else {
            return nil
        }
        let referenceSeconds: Double
        if rawValue.magnitude >= UInt64(nanosecondsThreshold) {
            referenceSeconds = Double(rawValue) / 1_000_000_000
        } else {
            referenceSeconds = Double(rawValue)
        }
        return Date(timeIntervalSinceReferenceDate: referenceSeconds)
    }

    internal static func rawReferenceSeconds(from date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }
}
