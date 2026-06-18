import Foundation

/// The app-owned coarse kind of a conversation's last act.
///
/// A 1:1 mirror of the engine's `StowerConversationLastMessageKind` (the same five
/// cases), kept under a distinct name so the board views and the pure non-text
/// rule never import the engine — exactly as `StowerStartupDebtConfig` mirrors the
/// engine `StowerDebtConfig`. The engine-coupled `StowerMessagesMapping` translates
/// the engine kind into this 1:1.
internal enum StowerLastMessageKind: Sendable, Equatable, CaseIterable {
    /// A text message; its body is available in the row/line text.
    case text

    /// A link preview; the URL is kept in the text.
    case link

    /// An attachment of any type (photo, file, voice note, video, sticker).
    case attachment

    /// A non-URL app/extension balloon (payment, FindMy, …).
    case app

    /// Any other content the row alone cannot classify.
    case other
}
