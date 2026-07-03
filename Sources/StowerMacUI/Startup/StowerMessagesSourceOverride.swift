import Foundation

/// A DEBUG-only override for the Messages database the board reads.
///
/// The app normally reads the live database at the engine's own
/// `StowerChatDatabaseReader.defaultSourceURL` (the user's Messages store).
/// A dev/demo build can instead point the board at a curated database — e.g. the
/// send-free demo database `Scripts/generate-demo-db.py` writes — by launching with
/// `STOWER_MESSAGES_DB` set to that file's path. This is how the relationship-debt
/// board is demoed without swapping (and risking) the user's real Messages history.
///
/// Resolution mirrors `StowerLicenseConfig`: a pure, environment-injected function
/// so both branches unit test, gated to **DEBUG only**. A Release build passes
/// `allowOverrides: false` and always returns `nil`, so a launch-environment
/// variable can never redirect a shipped binary off the real database. `nil` means
/// "no override" — the caller omits the argument and the engine's default applies.
///
/// It deliberately does **not** verify the path exists (that would need banned
/// direct filesystem access in the UI slice, `precheck.sh` 6d); a missing or
/// unreadable path surfaces as an ordinary startup error from the engine's reader.
internal enum StowerMessagesSourceOverride {
    /// The launch-environment key that names the database file to read instead.
    private static let environmentKey = "STOWER_MESSAGES_DB"

    /// The override URL for the given environment, or `nil` to use the default.
    ///
    /// Pure (environment + flag injected) so both branches are unit tested. When
    /// `allowOverrides` is false, or the key is unset/blank, returns `nil`. A tilde
    /// in the value is expanded so `~/Library/...` works from a shell launch.
    internal static func effectiveSourceURL(
        environment: [String: String],
        allowOverrides: Bool
    ) -> URL? {
        guard allowOverrides else { return nil }
        guard let rawValue = environment[environmentKey] else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Whether the app is running against an overridden (demo) database right now.
    ///
    /// True only in a DEBUG build launched with `STOWER_MESSAGES_DB` (always false in
    /// Release). Callers use it to switch on demo mode — e.g. suppressing the
    /// Contacts-access banner, whose names the injected demo resolver already fills in.
    internal static var isActive: Bool { resolved != nil }

    /// The override the app runs with: `STOWER_MESSAGES_DB` in DEBUG only, else `nil`.
    internal static let resolved: URL? = {
        #if DEBUG
            let allowOverrides = true
        #else
            let allowOverrides = false
        #endif
        return effectiveSourceURL(
            environment: ProcessInfo.processInfo.environment,
            allowOverrides: allowOverrides
        )
    }()
}
