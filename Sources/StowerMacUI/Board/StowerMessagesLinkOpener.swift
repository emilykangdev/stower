import AppKit
import Foundation

/// The one isolated opener for the engine-supplied Messages deep link.
///
/// Mirrors `StowerSystemSettingsOpener`: an injected
/// `@Sendable @MainActor (URL) -> Bool` over `NSWorkspace.shared.open`, so
/// previews/tests don't launch Messages. The app never constructs the URL — the
/// engine forms it and carries it on the row's `deepLink`; this only opens it.
internal struct StowerMessagesLinkOpener: Sendable {
    private let open: @Sendable @MainActor (URL) -> Bool

    /// Creates an opener.
    ///
    /// - Parameter open: Opens the URL and reports whether it opened; injectable so
    ///   tests/previews record instead of launching Messages.
    internal init(
        open: @escaping @Sendable @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.open = open
    }

    /// Opens the engine-supplied deep link.
    ///
    /// - Parameter url: The row's `deepLink`, formed by the engine.
    /// - Returns: Whether the URL actually opened.
    @MainActor @discardableResult internal func openLink(_ url: URL) -> Bool {
        open(url)
    }
}
