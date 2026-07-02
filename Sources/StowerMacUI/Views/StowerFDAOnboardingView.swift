import SwiftUI

/// The Full Disk Access onboarding screen — the trust moment.
///
/// It leads with reassurance (local-only, on-device, Messages-only) before
/// sending a nervous user to a global System Settings toggle and gives a numbered
/// recovery path. When access is still missing after a Check Again, it shows
/// escalating quit-and-reopen copy — a distinct sub-state, not a silent re-render.
internal struct StowerFDAOnboardingView: View {
    internal let stillMissing: Bool
    internal let onOpenSettings: () -> Void
    internal let onCheckAgain: () -> Void
    internal let onQuit: () -> Void

    internal var body: some View {
        StowerOnboardingPane(
            title: "Stower reads your Messages on this Mac to find messages you might "
                + "want to respond to."
        ) {
            StowerPaneIcon("lock.shield")
        } content: {
            VStack(alignment: .leading, spacing: Self.blockSpacing) {
                StowerTrustBlock()
                if stillMissing {
                    StowerStillMissingCallout()
                }
                StowerNumberedSteps()
            }
        } actions: {
            actionButtons
        }
    }

    @ViewBuilder private var actionButtons: some View {
        VStack(spacing: Self.actionSpacing) {
            Button("Open System Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button("Check Again", action: onCheckAgain)
                .buttonStyle(.bordered)
            if stillMissing {
                Button("Quit Stower", action: onQuit)
                    .buttonStyle(.link)
            }
        }
    }

    private static let blockSpacing: CGFloat = 16
    private static let actionSpacing: CGFloat = 8
}

/// The prominent local-only reassurance shown near the headline.
private struct StowerTrustBlock: View {
    var body: some View {
        Label(
            "Stower contacts our licensing server only to manage your free trial and "
                + "purchase — nothing else. Your messages never leave your Mac, and judging "
                + "runs on an on-device model only.",
            systemImage: "checkmark.shield.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(Self.tintOpacity), in: .rect(cornerRadius: Self.corner))
    }

    private static let padding: CGFloat = 12
    private static let corner: CGFloat = 10
    private static let tintOpacity: Double = 0.12
}

/// The escalating recovery copy shown only after a Check Again still fails.
private struct StowerStillMissingCallout: View {
    var body: some View {
        Label(
            "Stower still can't see Messages. After turning it on, macOS may need you to quit "
                + "and reopen Stower.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(Self.tintOpacity), in: .rect(cornerRadius: Self.corner))
    }

    private static let padding: CGFloat = 12
    private static let corner: CGFloat = 10
    private static let tintOpacity: Double = 0.15
}

/// The why-and-how: one reason sentence plus the numbered Settings path.
private struct StowerNumberedSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            Text(
                "Full Disk Access is the macOS toggle that lets an app read the Messages "
                    + "database. Here's the path:"
            )
            .foregroundStyle(.secondary)
            stepRow(1, "Open System Settings.")
            stepRow(2, "Turn on Stower under Full Disk Access.")
            stepRow(3, "If it still says access is missing, quit and reopen Stower.")
        }
        .font(.callout)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.numberSpacing) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }

    private static let lineSpacing: CGFloat = 8
    private static let numberSpacing: CGFloat = 6
}
