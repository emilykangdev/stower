import Foundation

/// Coarse bucketing helpers for anonymous analytics parameters.
///
/// Buckets prevent re-identification by collapsing continuous values into
/// discrete tokens. All bucketing is done before the value reaches the
/// typed-event API — the reporter never receives raw counts or durations.
///
/// Result-count bucket edges (brief taxonomy): 0 / 1–5 / 6–20 / 20+.
/// Duration bucket edges: <5s / 5–30s / 30s–5min / 5min+.
internal enum StowerAnalyticsBucket {
    // MARK: — Result count

    /// Buckets a raw result count into a coarse anonymous token.
    ///
    /// Edges: 0 · 1–5 · 6–20 · 21+.
    /// - Parameter count: The raw, exact result count.
    /// - Returns: A bucket string safe to include in a signal parameter.
    internal static func resultCount(_ count: Int) -> String {
        switch count {
        case 0: return "0"
        case 1...5: return "1-5"
        case 6...20: return "6-20"
        default: return "21+"
        }
    }

    // MARK: — Duration

    /// Buckets a time interval (in seconds) into a coarse anonymous token.
    ///
    /// Edges: <5s · 5–30s · 30s–5min · 5min+.
    /// - Parameter seconds: The raw, exact duration in seconds.
    /// - Returns: A bucket string safe to include in a signal parameter.
    internal static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5: return "under_5s"
        case 5..<30: return "5_30s"
        case 30..<300: return "30s_5min"
        default: return "over_5min"
        }
    }
}
