import AppKit
import Foundation

/// Presents the `NSOpenPanel` that grants Stower a security-scoped bookmark
/// for the user's Messages folder, validates the selection, and returns the
/// bookmark `Data` — never persisting it.
///
/// The ONE implementation shared by all three ephemeral-picker call sites
/// (the GUI app's onboarding flow, `StowerCLI`, and `StowerChatDBInspector`,
/// JC7): each caller owns its own persistence policy (the GUI persists via
/// `StowerUserDefaultsItem`; `StowerCLI`/`StowerChatDBInspector` never persist
/// at all, JC1) so this type stays a pure present-validate-return step.
///
/// `StowerMacUI`'s second `public` symbol ever, alongside `StowerRootView`
/// (JC7) — a deliberate, named exception to the module's one-public-symbol
/// convention, made so `StowerCLI`/`StowerChatDBInspector` exercise the exact
/// production picker code instead of a duplicated reimplementation.
public enum StowerMessagesAccessPicker {
    /// Presents the panel pre-navigated to `~/Library/Messages`, validates the
    /// selected folder contains the Messages database, and creates a fresh
    /// security-scoped bookmark for it.
    ///
    /// - Returns: The bookmark `Data` for the user's selection, or `nil` if
    ///   the user cancelled the panel.
    /// - Throws: `StowerMessagesAccessPickerError.selectionMissingDatabase`
    ///   when the selected folder does not contain the Messages database, or
    ///   an underlying error if bookmark creation itself fails.
    @MainActor
    public static func presentAndCreateBookmark() throws -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = Self.panelMessage
        panel.directoryURL = Self.defaultDirectoryURL
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        let databaseURL = selectedURL.appendingPathComponent(
            StowerMessagesAccessConstants.databaseFileName
        )
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw StowerMessagesAccessPickerError.selectionMissingDatabase
        }
        return try selectedURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Pre-navigates the panel straight to the Messages folder so the user
    /// never has to find a hidden Library folder themselves.
    private static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages", isDirectory: true)
    }

    private static let panelMessage =
        "Select your Messages folder to give Stower access to your messages."
}

/// A failure presenting or validating the Messages-access picker.
public enum StowerMessagesAccessPickerError: Error, LocalizedError, Sendable {
    /// The user-selected folder does not contain the Messages database.
    case selectionMissingDatabase

    /// A user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .selectionMissingDatabase:
            return "That folder doesn't contain your Messages data. "
                + "Please select the Messages folder."
        }
    }
}
