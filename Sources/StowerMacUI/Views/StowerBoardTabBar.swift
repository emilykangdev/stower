import SwiftUI

/// The board's 3-way tab control: a pill-shaped segmented row with the selected
/// tab shown as a solid inset capsule, replacing the prior system
/// `Picker(.segmented)`.
///
/// Lives in the content area (not an `NSToolbar` item), so it isn't bound by the
/// HIG's toolbar-item borderless/no-fill rule — the approved board-header-revamp
/// mockup's pill shape is a content-layer personality choice, matching how Raycast
/// and Linear render their own tab rows rather than the system segmented control.
internal struct StowerBoardTabBar: View {
    @Binding internal var selection: StowerBoardTab

    /// Coordinates the selected pill's slide animation across tab buttons.
    @Namespace private var selectionNamespace

    internal var body: some View {
        HStack(spacing: 2) {
            ForEach(StowerBoardTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Board tab")
    }

    private func tabButton(_ tab: StowerBoardTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            Text(tab.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, StowerBoardTheme.tabPillHorizontalPadding)
                .padding(.vertical, StowerBoardTheme.tabPillVerticalPadding)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selectedTab", in: selectionNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: Self.selectionAnimationDuration), value: selection)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Duration of the selected pill's slide-between-tabs animation.
    private static let selectionAnimationDuration: Double = 0.2
}
