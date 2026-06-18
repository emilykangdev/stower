import SwiftUI

/// The shared native utility-pane layout every startup screen uses, so the six
/// screens stay visually consistent: a header (an icon or a progress spinner), a
/// title, an optional message, freeform content, and a trailing actions row —
/// centered, with a capped text width on a resizable window.
internal struct StowerOnboardingPane<Header: View, Content: View, Actions: View>: View {
    private let title: String
    private let message: String?
    @ViewBuilder private let header: () -> Header
    @ViewBuilder private let content: () -> Content
    @ViewBuilder private let actions: () -> Actions

    internal init(
        title: String,
        message: String? = nil,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.header = header
        self.content = content
        self.actions = actions
    }

    internal var body: some View {
        // A ScrollView with a viewport-height minimum keeps the content centered
        // when it fits, but lets a tall pane (long FDA copy, or large Dynamic
        // Type) scroll so the recovery actions stay reachable instead of clipping
        // below the window's minimum height.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: StowerOnboardingPaneLayout.sectionSpacing) {
                    header()
                    titleBlock
                    content()
                    actions()
                }
                .frame(maxWidth: StowerOnboardingPaneLayout.maxTextWidth)
                .padding(StowerOnboardingPaneLayout.outerPadding)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: StowerOnboardingPaneLayout.titleSpacing) {
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

/// Layout constants for `StowerOnboardingPane` (a generic type can't hold static
/// stored properties, so they live in this co-located namespace).
private enum StowerOnboardingPaneLayout {
    static let sectionSpacing: CGFloat = 20
    static let titleSpacing: CGFloat = 8
    static let maxTextWidth: CGFloat = 560
    static let outerPadding: CGFloat = 32
}

/// A header icon sized and tinted consistently for the onboarding panes.
internal struct StowerPaneIcon: View {
    private let systemName: String
    private let tint: Color

    internal init(_ systemName: String, tint: Color = .accentColor) {
        self.systemName = systemName
        self.tint = tint
    }

    internal var body: some View {
        Image(systemName: systemName)
            .font(.system(size: Self.iconSize, weight: .regular))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private static let iconSize: CGFloat = 44
}
