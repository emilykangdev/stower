import Foundation
import Testing

@testable import StowerMacUI

/// Verifies the persistence contract of `StowerSettingsTab`.
///
/// The `@AppStorage` key bridges the board's gear menu and the Settings `TabView`
/// across scenes; the `String` raw values are what UserDefaults stores.
///
/// The runtime tab-presentation behavior (`openSettings()` + `TabView(selection:)`) is
/// a SwiftUI concern that isn't headlessly unit-testable; it's a manual build-and-run
/// checklist item, not asserted here.
@Suite internal struct StowerSettingsTabTests {
    @Test("storageKey is the canonical dotted UserDefaults key")
    internal func storageKeyIsStable() {
        #expect(StowerSettingsTab.storageKey == "stower.settings.selectedTab")
    }

    @Test("each case round-trips through its String raw value")
    internal func rawValueRoundTrips() {
        #expect(StowerSettingsTab.privacy.rawValue == "privacy")
        #expect(StowerSettingsTab.updates.rawValue == "updates")
        #expect(StowerSettingsTab(rawValue: "privacy") == .privacy)
        #expect(StowerSettingsTab(rawValue: "updates") == .updates)
        #expect(StowerSettingsTab(rawValue: "nope") == nil)
    }
}
