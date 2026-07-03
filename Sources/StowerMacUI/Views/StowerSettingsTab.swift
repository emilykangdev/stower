/// The identity of a tab in the Settings scene's `TabView`.
///
/// Backs the `@AppStorage` selection binding shared across two scenes: the board's
/// gear menu (`WindowGroup`) writes the desired tab before calling `openSettings()`,
/// and `StowerSettingsView`'s `TabView(selection:)` (the `Settings` scene) reads it.
/// `String`-raw so `@AppStorage` can persist it directly (UserDefaults). Public
/// because the StowerMac app target tags its Updates pane with `.updates`.
public enum StowerSettingsTab: String {
    /// The Privacy pane (`StowerPrivacySettingsView`); the default/first tab.
    case privacy
    /// The Updates pane (the updater, supplied by the StowerMac app target).
    case updates

    /// The UserDefaults key backing the shared tab-selection `@AppStorage`.
    ///
    /// One canonical string, referenced everywhere via `StowerSettingsTab.storageKey`
    /// so the board button and the Settings `TabView` can never drift apart.
    public static let storageKey = "stower.settings.selectedTab"
}
