import SwiftUI

/// A non-blocking bar above the board offering to turn handles into Contacts names.
///
/// Shown only while the board has rows and Contacts is not authorized (the
/// view-model's `showsContactsAccessBanner`). Its button is the durable recovery
/// path a one-shot system prompt can't provide: tapping it either raises the system
/// prompt (never asked) or opens System Settings → Contacts (denied). The banner
/// disappears the moment access is granted and the board reloads into names.
internal struct StowerContactsAccessBanner: View {
    internal let actionTitle: String
    internal let action: () -> Void

    internal var body: some View {
        HStack(spacing: StowerBoardTheme.bannerSpacing) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Showing phone numbers")
                    .font(.callout.weight(.medium))
                Text("Allow Contacts access to see names instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, StowerBoardTheme.bannerHorizontalPadding)
        .padding(.vertical, StowerBoardTheme.bannerVerticalPadding)
        .background(StowerBoardTheme.bannerBackground)
        .accessibilityElement(children: .combine)
    }
}
