import SwiftUI

/// The Messages-access onboarding screen — the trust moment.
///
/// It leads with reassurance (local-only, on-device, Messages-only) before
/// asking the user to select their Messages folder in the picker. When access
/// is still missing after a Check Again, it shows escalating quit-and-reopen
/// copy — a distinct sub-state, not a silent re-render.
internal struct StowerMessagesAccessOnboardingView: View {
    internal let stillMissing: Bool
    internal let onPresentPicker: () -> Void
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
                StowerAccessSteps()
            }
        } actions: {
            actionButtons
        }
    }

    @ViewBuilder private var actionButtons: some View {
        VStack(spacing: Self.actionSpacing) {
            Button("Select Messages Folder…", action: onPresentPicker)
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
            "Your messages never leave your Mac — judging runs on an on-device model "
                + "only. Stower also contacts our licensing server to manage your free "
                + "trial and purchase, and (optionally, off anytime in Settings → Privacy) "
                + "sends anonymous analytics and crash reports.",
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
            "Stower still can't see Messages. The previously selected folder may no longer "
                + "be accessible — select it again below.",
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

/// The why-and-how: one reason sentence plus the numbered picker path.
private struct StowerAccessSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            Text(
                "In the dialog that opens, select the Messages folder and click Open. "
                    + "Here's the path:"
            )
            .foregroundStyle(.secondary)
            stepRow(1, "Click Select Messages Folder below.")
            stepRow(2, "Select the Messages folder and click Open.")
            stepRow(3, "If it still says access is missing, try again.")
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
