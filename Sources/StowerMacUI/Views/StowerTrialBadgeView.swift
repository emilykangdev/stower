import SwiftUI

/// A quiet, dismissible status bar showing the active free-trial end date.
///
/// Renders "Free trial · ends <formatted date>" (static date, never a countdown)
/// and a dismiss control. **Has no buy affordance** — payment lives exclusively
/// in the board toolbar's gear menu. The caller gates on whether the badge should
/// appear; this view is always visible when it is in the hierarchy.
internal struct StowerTrialBadgeView: View {
    /// The trial status data decoded from the signed machine file.
    internal let badge: StowerTrialBadge

    /// Called when the user dismisses the badge; the caller persists the flag.
    internal let onDismiss: () -> Void

    internal var body: some View {
        HStack(spacing: StowerBoardTheme.bannerSpacing) {
            Image(systemName: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.endLabel(for: badge.expiry))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Self.accessibilityLabel(for: badge.expiry))
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss trial badge")
        }
        .padding(.horizontal, StowerBoardTheme.bannerHorizontalPadding)
        .padding(.vertical, StowerBoardTheme.bannerVerticalPadding)
        .background(Self.badgeBackground)
    }

    /// The canonical "Free trial · ends <date>" status label — the single source
    /// of truth for this string, reused by the board toolbar's gear menu
    /// (`StowerBoardView.licenseMenu`) so the badge and the menu can never show a
    /// differently-formatted date.
    internal static func endLabel(for expiry: Date) -> String {
        "Free trial · ends \(dateFormatter.string(from: expiry))"
    }

    /// A richer accessibility label that spells out the full date context.
    private static func accessibilityLabel(for expiry: Date) -> String {
        "Free trial ends \(dateFormatter.string(from: expiry))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let badgeBackground = Color.secondary.opacity(0.1)
}

#Preview("Active trial") {
    StowerTrialBadgeView(
        badge: StowerTrialBadge(expiry: Date().addingTimeInterval(30 * 24 * 3600)),
        onDismiss: {}
    )
    .frame(width: 400)
}
