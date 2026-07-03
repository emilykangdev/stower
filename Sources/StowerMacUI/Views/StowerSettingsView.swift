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

    /// The selected tab, shared with the board's gear menu via `@AppStorage`.
    ///
    /// The board writes `.privacy` before `openSettings()` so "Privacy…" always
    /// lands on the Privacy pane; the OS `⌘,` path restores the last-selected tab
    /// from the same key. Each pane carries a `.tag(StowerSettingsTab...)` so the
    /// binding can represent it.
    @AppStorage(StowerSettingsTab.storageKey) private var selectedTab: StowerSettingsTab = .privacy

    /// Creates the settings view.
    ///
    /// - Parameter additionalPanes: extra preference tabs to render after Privacy.
    ///   Each must apply its own `.tabItem`. Defaults to none.
    public init(@ViewBuilder additionalPanes: () -> AdditionalPanes = { EmptyView() }) {
        self.additionalPanes = additionalPanes()
    }

    /// The settings scene body: a tab view housing all preference panes.
    public var body: some View {
        TabView(selection: $selectedTab) {
            StowerPrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .tag(StowerSettingsTab.privacy)
            additionalPanes
        }
        .frame(width: 480, height: 320)
    }
}
