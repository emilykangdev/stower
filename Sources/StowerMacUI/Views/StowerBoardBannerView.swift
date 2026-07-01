import SwiftUI

/// Renders the board's one bottom-banner slot for the current
/// `StowerBoardBannerState` (F2/F3, §What → "Money-moment states").
///
/// `.none` renders nothing (an empty view that reserves no space); every other
/// case renders exactly one banner, so the slot never stacks two messages.
internal struct StowerBoardBannerView: View {
    internal let state: StowerBoardBannerState
    /// Opens the Lemon Squeezy checkout in the browser (F3's Buy action).
    internal let onBuy: () -> Void
    /// Jumps to the key-entry screen (F2's Enter license key action).
    internal let onEnterKey: () -> Void
    /// Persists the trial-badge dismissal flag (the pre-F3 badge only).
    internal let onDismissTrial: () -> Void

    internal var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .trialBadge(let expiry):
            StowerTrialBadgeView(badge: StowerTrialBadge(expiry: expiry), onDismiss: onDismissTrial)
        case .buyNudge:
            buyNudgeBanner
        case .enterKey:
            enterKeyBanner
        }
    }

    /// F3 — trial ends within a day; not dismissible (the highest-intent moment).
    private var buyNudgeBanner: some View {
        HStack(spacing: StowerBoardTheme.bannerSpacing) {
            Image(systemName: "hourglass")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(Self.buyNudgeMessage)
                .font(.callout)
            Spacer(minLength: 0)
            Button("Buy Stower", action: onBuy)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, StowerBoardTheme.bannerHorizontalPadding)
        .padding(.vertical, StowerBoardTheme.bannerVerticalPadding)
        .background(StowerBoardTheme.bannerBackground)
    }

    /// F2 — returned from checkout this session, no license stored yet.
    private var enterKeyBanner: some View {
        HStack(spacing: StowerBoardTheme.bannerSpacing) {
            Image(systemName: "envelope")
                .font(.callout)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(Self.enterKeyMessage)
                .font(.callout)
            Spacer(minLength: 0)
            Button("Enter license key", action: onEnterKey)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, StowerBoardTheme.bannerHorizontalPadding)
        .padding(.vertical, StowerBoardTheme.bannerVerticalPadding)
        .background(StowerBoardTheme.bannerBackground)
    }

    private static let buyNudgeMessage =
        "Your free trial ends soon — Buy Stower to keep your board."
    private static let enterKeyMessage =
        "Finished your purchase? Enter the license key from your email."
}

#Preview("Trial badge") {
    StowerBoardBannerView(
        state: .trialBadge(expiry: Date().addingTimeInterval(5 * 24 * 3600)),
        onBuy: {},
        onEnterKey: {},
        onDismissTrial: {}
    )
    .frame(width: 420)
}

#Preview("F3 — buy nudge") {
    StowerBoardBannerView(
        state: .buyNudge(expiry: Date().addingTimeInterval(20 * 3600)),
        onBuy: {},
        onEnterKey: {},
        onDismissTrial: {}
    )
    .frame(width: 420)
}

#Preview("F2 — enter key") {
    StowerBoardBannerView(
        state: .enterKey,
        onBuy: {},
        onEnterKey: {},
        onDismissTrial: {}
    )
    .frame(width: 420)
}
