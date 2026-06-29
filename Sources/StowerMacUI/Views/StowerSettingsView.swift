import SwiftUI

/// The Settings scene root, housing all app preferences.
///
/// Presented via the `Settings { }` scene in `StowerMacApp`. Houses the
/// Privacy pane (analytics consent) and any future preference panes.
public struct StowerSettingsView: View {
    /// Creates the settings view.
    public init() {}

    /// The settings scene body: a tab view housing all preference panes.
    public var body: some View {
        TabView {
            StowerPrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
        }
        .frame(width: 480, height: 320)
    }
}
