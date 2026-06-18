import AppKit
import Foundation

/// A System Settings pane this app deep-links the user to.
internal enum StowerSystemSettingsPane: Sendable {
    /// Privacy & Security → Full Disk Access.
    case fullDiskAccess

    /// Apple Intelligence & Siri.
    case appleIntelligence
}

/// The one isolated opener for every System Settings deep link.
///
/// Landing the user on the exact pane is a real UX requirement during the trust
/// moment, not a nice-to-have. The pane URLs use the Apple-undocumented
/// `x-apple.systempreferences:` sub-pane scheme, so they are version-fragile and
/// must be confirmed on real macOS 26 hardware (a QA item). Each is `guard
/// let`-constructed — never force-unwrapped — and a nil/failed pane URL falls back
/// to general System Settings so a wrong or changed string never strands the user.
internal struct StowerSystemSettingsOpener: Sendable {
    private let open: @Sendable @MainActor (URL) -> Bool

    /// Creates an opener. `open` returns whether the URL actually opened and is
    /// injectable so previews/tests don't launch System Settings.
    internal init(
        open: @escaping @Sendable @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.open = open
    }

    /// Opens `pane`, falling back to general System Settings if its URL is absent
    /// OR fails to open.
    ///
    /// The pane strings are Apple-undocumented and version-fragile, so a
    /// parseable-but-wrong URL can fail to open — falling back on a `false` result
    /// (not just a `nil` URL) is what keeps the user from being stranded.
    @MainActor internal func openPane(_ pane: StowerSystemSettingsPane) {
        if let paneURL = Self.paneURL(for: pane), open(paneURL) {
            return
        }
        if let fallback = Self.generalSettingsURL {
            _ = open(fallback)
        }
    }

    /// The deep-link URL for `pane`, or `nil` if the (fragile) string fails to
    /// parse — in which case `openPane` uses the general-settings fallback.
    internal static func paneURL(for pane: StowerSystemSettingsPane) -> URL? {
        switch pane {
        case .fullDiskAccess:
            return URL(string: fullDiskAccessURLString)
        case .appleIntelligence:
            return URL(string: appleIntelligenceURLString)
        }
    }

    /// The safety-net URL: the top of System Settings.
    internal static var generalSettingsURL: URL? {
        URL(string: generalSettingsURLString)
    }

    /// Confirm on macOS 26 — see the opener's QA checklist item in the plan.
    private static let fullDiskAccessURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Confirm on macOS 26 — see the opener's QA checklist item in the plan.
    private static let appleIntelligenceURLString =
        "x-apple.systempreferences:com.apple.Siri-Settings.extension"

    private static let generalSettingsURLString = "x-apple.systempreferences:"
}
