import Foundation

/// The presentation of a conversation's last act: either the sender's verbatim
/// text, or a per-kind placeholder standing in for a non-text act.
///
/// The one non-text rule, shared by board rows and thread bubbles: `text == nil`
/// **or** empty/whitespace-only yields a per-kind placeholder
/// (`isPlaceholder == true`) the view renders italic and angle-bracketed
/// (`<Sent an attachment>`) so it reads as a stand-in for a media act, never the
/// sender's literal words; any non-empty, non-whitespace text is the verbatim
/// label (`isPlaceholder == false`). Pure and over the app-owned
/// `StowerLastMessageKind`, so it stays testable without importing the engine.
internal struct StowerLastMessageSummary: Sendable, Equatable, Hashable {
    /// The text to display: verbatim message text, or a placeholder label.
    internal let label: String

    /// Whether `label` is a non-text placeholder (render italic + bracketed).
    internal let isPlaceholder: Bool

    /// Applies the non-text rule to a last act.
    ///
    /// - Parameters:
    ///   - kind: The act's kind, selecting the placeholder when text is absent.
    ///   - text: The act's text, or `nil` for a non-text act.
    /// - Returns: The verbatim text, or the per-kind placeholder when text is
    ///   `nil`/empty/whitespace-only.
    internal static func make(
        kind: StowerLastMessageKind,
        text: String?
    ) -> StowerLastMessageSummary {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return StowerLastMessageSummary(label: text, isPlaceholder: false)
        }
        return StowerLastMessageSummary(label: placeholderLabel(for: kind), isPlaceholder: true)
    }

    /// The fallback label for a non-text act of `kind`.
    private static func placeholderLabel(for kind: StowerLastMessageKind) -> String {
        switch kind {
        case .text: return "Sent a message"
        case .link: return "Sent a link"
        case .attachment: return "Sent an attachment"
        case .app: return "Sent an app message"
        case .other: return "Sent a message"
        }
    }
}
