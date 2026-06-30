import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle update lifecycle for the StowerMac app.
///
/// Wraps `SPUStandardUpdaterController` and exposes the two user-facing
/// update preferences as `@Published` properties so SwiftUI views can bind
/// directly. The controller starts the updater at init time; Sparkle reads
/// `SUFeedURL` and `SUPublicEDKey` from the built `Info.plist`.
///
/// All mutations happen on the main actor because `SWIFT_DEFAULT_ACTOR_ISOLATION`
/// is `MainActor` for this target and Sparkle's updater properties are
/// documented as main-thread-only.
@MainActor
final class StowerUpdaterController: NSObject, ObservableObject {

    private let controller: SPUStandardUpdaterController

    /// Whether Sparkle checks for updates on its automatic schedule.
    ///
    /// Toggling this off also makes the download-and-install preference
    /// inert — setting downloads while checks are off is a silent no-op.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// Whether Sparkle downloads and installs updates without prompting.
    ///
    /// Meaningless (and disabled in the UI) when `automaticallyChecksForUpdates`
    /// is `false`. The user can still trigger a manual check via
    /// `checkForUpdates()` regardless of this setting.
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        super.init()
    }

    /// Triggers an immediate, user-initiated update check.
    ///
    /// Surfaces the standard Sparkle "Check for Updates…" panel. Safe to call
    /// even when automatic checks are disabled.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
