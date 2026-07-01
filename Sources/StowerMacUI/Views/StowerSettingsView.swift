import SwiftUI

/// The Settings scene root, housing all app preferences.
///
/// Presented via the single `Settings { }` scene in `StowerMacApp`. Houses the
/// Privacy pane (analytics consent) plus any `additionalPanes` the app target
/// supplies — e.g. the updater pane, which lives in the StowerMac app target and
/// cannot be referenced from this library module. Each supplied pane must carry
/// its own `.tabItem`. SwiftUI permits only one `Settings` scene, so all panes
/// must funnel through here rather than a second scene.
public struct StowerSettingsView<AdditionalPanes: View>: View {
    private let additionalPanes: AdditionalPanes

    /// Creates the settings view.
    ///
    /// - Parameter additionalPanes: extra preference tabs to render after Privacy.
    ///   Each must apply its own `.tabItem`. Defaults to none.
    public init(@ViewBuilder additionalPanes: () -> AdditionalPanes = { EmptyView() }) {
        self.additionalPanes = additionalPanes()
    }

    /// The settings scene body: a tab view housing all preference panes.
    public var body: some View {
        TabView {
            StowerPrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
            additionalPanes
        }
        .frame(width: 480, height: 320)
    }
}
