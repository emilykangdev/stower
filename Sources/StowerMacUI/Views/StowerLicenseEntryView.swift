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
    /// Backs out to the board.
    ///
    /// `nil` when there is nowhere to go back to (the hard paywall after an
    /// expired trial); non-nil only when the screen was opened voluntarily
    /// mid-trial (JC5), so the user is never trapped.
    internal let onBack: (() -> Void)?
    /// `true` while a prior `onActivate` call is still in flight — disables
    /// Activate so a rapid double-submit can't fire two concurrent `/activate`
    /// calls against Lemon Squeezy's finite `activation_limit`.
    internal let isActivating: Bool

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
                .disabled(!Self.isPlausibleKey(key) || isActivating)
            HStack(spacing: Self.helpSpacing) {
                if let onBack {
                    Button("Back to trial", action: onBack)
                }
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

    /// Activates the normalized key; a mis-formatted key or an in-flight
    /// activate can't submit (the Activate button is also disabled in both
    /// cases), so a stray keystroke never fires a pointless `/activate` call.
    private func activate() {
        guard Self.isPlausibleKey(key), !isActivating else { return }
        onActivate(normalizedKey)
    }

    /// Whether `rawKey`, once normalized, looks like a Lemon Squeezy key.
    ///
    /// The default Lemon Squeezy license key is a UUID of the form `8-4-4-4-12`
    /// hex digits. This is a cheap client gate so a single stray character can't
    /// fire a network `/activate`; Lemon Squeezy's server stays the real
    /// authority. If the store is ever switched to a custom key format, loosen
    /// this pattern.
    internal static func isPlausibleKey(_ rawKey: String) -> Bool {
        normalize(rawKey).wholeMatch(of: keyFormat) != nil
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
    private static var supportURL: URL? { URL(string: "mailto:\(supportEmail)") }
    private static let supportEmail = "emily@stower.app"
    private static let stripPrefixes = ["key:", "license key:", "license_key="]
    /// Lemon Squeezy's default license-key shape: a UUID (`8-4-4-4-12` hex).
    private static let keyFormat =
        /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
    private static let fieldSpacing: CGFloat = 6
    private static let actionSpacing: CGFloat = 8
    private static let helpSpacing: CGFloat = 16
}

#Preview("No error (hard paywall, no Back)") {
    StowerLicenseEntryView(
        key: .constant(""),
        error: nil,
        onActivate: { _ in },
        onBuy: {},
        onBack: nil,
        isActivating: false
    )
}

#Preview("Mid-trial visit (with Back)") {
    StowerLicenseEntryView(
        key: .constant("80e15db5-c796-436b-850c-8f9c98a48abe"),
        error: nil,
        onActivate: { _ in },
        onBuy: {},
        onBack: {},
        isActivating: false
    )
}

#Preview("Invalid key") {
    StowerLicenseEntryView(
        key: .constant("ABCD-1234"),
        error: .invalid,
        onActivate: { _ in },
        onBuy: {},
        onBack: nil,
        isActivating: false
    )
}

#Preview("Could not reach") {
    StowerLicenseEntryView(
        key: .constant("ABCD-1234"),
        error: .couldNotReach,
        onActivate: { _ in },
        onBuy: {},
        onBack: nil,
        isActivating: false
    )
}

#Preview("Activating") {
    StowerLicenseEntryView(
        key: .constant("80e15db5-c796-436b-850c-8f9c98a48abe"),
        error: nil,
        onActivate: { _ in },
        onBuy: {},
        onBack: nil,
        isActivating: true
    )
}
