import SwiftUI

/// The license-key entry screen: paste the key from the Lemon Squeezy purchase
/// email, activate once, then into onboarding.
///
/// Mirrors `StowerModelUnavailableView` on `StowerOnboardingPane`. The typed text
/// is a `@Binding` owned by `StowerRootView` (whose identity is stable), so it
/// survives the `.checkingLicense` spinner round-trip and is still there when an
/// activation error returns to this screen. This is the only screen from which
/// the app makes a network call; the message says so.
internal struct StowerLicenseEntryView: View {
    @Binding internal var key: String
    internal let error: StowerLicenseGateError?
    internal let onActivate: (String) -> Void

    @FocusState private var fieldFocused: Bool

    internal var body: some View {
        StowerOnboardingPane(title: Self.title, message: Self.message) {
            StowerPaneIcon("key.fill")
        } content: {
            entryField
        } actions: {
            actions
        }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var entryField: some View {
        VStack(alignment: .leading, spacing: Self.fieldSpacing) {
            TextField("License key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit(activate)
                .accessibilityLabel("License key")
                .accessibilityHint(error.map(Self.errorMessage) ?? "")
            if let error {
                Text(Self.errorMessage(error))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: Self.actionSpacing) {
            Button("Activate", action: activate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedKey.isEmpty)
            HStack(spacing: Self.helpSpacing) {
                if let supportURL = Self.supportURL {
                    Link("Lost your key?", destination: supportURL)
                }
                if let productURL = Self.productURL {
                    Link("Buy a license", destination: productURL)
                }
            }
            .font(.callout)
            .buttonStyle(.link)
        }
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Activates the trimmed key; a whitespace-only field can't submit (the
    /// Activate button is also disabled in that case).
    private func activate() {
        let trimmed = trimmedKey
        guard !trimmed.isEmpty else { return }
        onActivate(trimmed)
    }

    /// The non-blaming, internals-free copy for each entry-screen error.
    private static func errorMessage(_ error: StowerLicenseGateError) -> String {
        switch error {
        case .invalid:
            return "That key didn't work. Double-check you copied the whole key from your "
                + "purchase email. Still stuck? Contact support."
        case .couldNotReach:
            return "Couldn't reach the license server. Stower needs to connect once to verify "
                + "your purchase — check your connection, then click Activate again."
        }
    }

    private static let title = "Enter your license key"
    private static let message =
        "Paste the license key from your Lemon Squeezy purchase email. Stower connects once to "
        + "verify your purchase, then works entirely offline."
    private static var supportURL: URL? { URL(string: supportURLString) }
    private static var productURL: URL? { URL(string: productURLString) }
    private static let supportURLString = "mailto:support@stower.app"
    private static let productURLString = "https://stower.lemonsqueezy.com"
    private static let fieldSpacing: CGFloat = 6
    private static let actionSpacing: CGFloat = 8
    private static let helpSpacing: CGFloat = 16
}

#Preview("Invalid key") {
    StowerLicenseEntryView(key: .constant("ABCD-1234"), error: .invalid, onActivate: { _ in })
}

#Preview("Could not reach") {
    StowerLicenseEntryView(key: .constant("ABCD-1234"), error: .couldNotReach, onActivate: { _ in })
}
