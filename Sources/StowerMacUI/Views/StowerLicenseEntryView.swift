import SwiftUI

/// The license entry / paywall / connectivity screen, mode-driven by
/// `StowerLicenseEntryContext`.
///
/// Mirrors `StowerModelUnavailableView` on `StowerOnboardingPane` so the startup
/// screens stay visually consistent. There is no key field: Plan B deletes manual
/// activation. The buy contexts (`.trialExpired` / `.upgradeRequired`) carry the
/// device's `licenseID` so Buy opens the checkout bound to this license; the
/// connectivity contexts (`.connectOnce` / `.couldNotReach`) only retry.
internal struct StowerLicenseEntryView: View {
    internal let context: StowerLicenseEntryContext
    /// Opens the Lemon Squeezy checkout carrying the given `licenseID`.
    internal let onBuy: (String) -> Void
    /// Re-runs the license check (Re-check after purchase, or retry connectivity).
    internal let onRetry: () -> Void

    internal var body: some View {
        StowerOnboardingPane(title: title, message: message) {
            StowerPaneIcon(iconName, tint: .accentColor)
        } actions: {
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch context {
        case .trialExpired(let licenseID), .upgradeRequired(let licenseID):
            VStack(spacing: Self.actionSpacing) {
                Button(Self.buyTitle) { onBuy(licenseID) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(Self.recheckTitle, action: onRetry)
                    .buttonStyle(.bordered)
                supportLink
            }
        case .connectOnce, .couldNotReach:
            VStack(spacing: Self.actionSpacing) {
                Button(Self.retryTitle, action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                supportLink
            }
        }
    }

    @ViewBuilder private var supportLink: some View {
        if let supportURL = Self.supportURL {
            Link("Need help? Contact support", destination: supportURL)
                .font(.callout)
                .buttonStyle(.link)
        }
    }

    private var iconName: String {
        switch context {
        case .trialExpired: return "hourglass"
        case .upgradeRequired: return "arrow.up.circle"
        case .connectOnce, .couldNotReach: return "wifi"
        }
    }

    private var title: String {
        switch context {
        case .trialExpired: return "Your free trial has ended"
        case .upgradeRequired: return "Upgrade to keep using Stower"
        case .connectOnce: return "Connect once to start your free trial"
        case .couldNotReach: return "Couldn't reach the license server"
        }
    }

    private var message: String {
        switch context {
        case .trialExpired:
            return "Buy Stower to keep finding messages you might want to respond to. "
                + "After your purchase, click Re-check and you're back in."
        case .upgradeRequired:
            return "Your license doesn't cover this version of Stower yet. Upgrade to "
                + "unlock it, then click Re-check."
        case .connectOnce:
            return "Stower starts your free trial on this Mac with a one-time connection. "
                + "Check your internet, then try again."
        case .couldNotReach:
            return "Stower needs to reach the license server to check your access. Check "
                + "your connection, then try again."
        }
    }

    private static let buyTitle = "Buy Stower"
    private static let recheckTitle = "I've completed my purchase — Re-check"
    private static let retryTitle = "Try Again"
    private static var supportURL: URL? { URL(string: supportURLString) }
    private static let supportURLString = "mailto:support@stower.app"
    private static let actionSpacing: CGFloat = 8
}

#Preview("Trial expired") {
    StowerLicenseEntryView(
        context: .trialExpired(licenseID: "lic-1"),
        onBuy: { _ in },
        onRetry: {}
    )
}

#Preview("Upgrade required") {
    StowerLicenseEntryView(
        context: .upgradeRequired(licenseID: "lic-1"),
        onBuy: { _ in },
        onRetry: {}
    )
}

#Preview("Connect once") {
    StowerLicenseEntryView(context: .connectOnce, onBuy: { _ in }, onRetry: {})
}

#Preview("Could not reach") {
    StowerLicenseEntryView(context: .couldNotReach, onBuy: { _ in }, onRetry: {})
}
