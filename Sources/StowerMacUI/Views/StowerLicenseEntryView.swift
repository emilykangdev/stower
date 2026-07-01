import SwiftUI

/// The license-key entry / paywall screen: paste the key from the Lemon
/// Squeezy purchase email, activate once, then into the board.
///
/// Mirrors `StowerModelUnavailableView` on `StowerOnboardingPane`. The typed
/// text is a `@Binding` owned by `StowerRootView` (whose identity is stable),
/// so it survives an in-flight activate and is still there when an
/// activation error returns to this screen. This is the only screen from
/// which the app makes a network call; the message says so.
internal struct StowerLicenseEntryView: View {
    @Binding internal var key: String
    internal let error: StowerLicenseGateError?
    internal let onActivate: (String) -> Void
    /// Opens the Lemon Squeezy checkout in the browser.
    internal let onBuy: () -> Void

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
                .disabled(normalizedKey.isEmpty)
            HStack(spacing: Self.helpSpacing) {
                if let supportURL = Self.supportURL {
                    Link("Lost your key?", destination: supportURL)
                }
                Button("Buy a license", action: onBuy)
            }
            .font(.callout)
            .buttonStyle(.link)
        }
    }

    /// The typed key with paste-forgiveness applied: leading/trailing
    /// whitespace/newlines trimmed, then an obvious `key:` or URL prefix
    /// stripped, so a valid key with copy-paste junk isn't falsely rejected.
    private var normalizedKey: String {
        Self.normalize(key)
    }

    /// Activates the normalized key; an empty result can't submit (the
    /// Activate button is also disabled in that case).
    private func activate() {
        let normalized = normalizedKey
        guard !normalized.isEmpty else { return }
        onActivate(normalized)
    }

    /// Trims whitespace/newlines, then strips a leading `key:` label or a
    /// `https://…/` URL prefix a user might paste alongside the key itself.
    internal static func normalize(_ rawKey: String) -> String {
        var trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in stripPrefixes where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let lastSlash = trimmed.lastIndex(of: "/"), trimmed.lowercased().hasPrefix("http") {
            trimmed = String(trimmed[trimmed.index(after: lastSlash)...])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static let supportURLString = "mailto:support@stower.app"
    private static let stripPrefixes = ["key:", "license key:", "license_key="]
    private static let fieldSpacing: CGFloat = 6
    private static let actionSpacing: CGFloat = 8
    private static let helpSpacing: CGFloat = 16
}

#Preview("No error") {
    StowerLicenseEntryView(
        key: .constant(""),
        error: nil,
        onActivate: { _ in },
        onBuy: {}
    )
}

#Preview("Invalid key") {
    StowerLicenseEntryView(
        key: .constant("ABCD-1234"),
        error: .invalid,
        onActivate: { _ in },
        onBuy: {}
    )
}

#Preview("Could not reach") {
    StowerLicenseEntryView(
        key: .constant("ABCD-1234"),
        error: .couldNotReach,
        onActivate: { _ in },
        onBuy: {}
    )
}
