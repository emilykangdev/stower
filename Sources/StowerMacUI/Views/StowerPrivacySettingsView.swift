import SwiftUI

/// Settings → Privacy: the primary trust surface for diagnostics consent.
///
/// Shows the diagnostics toggle (default on) with honest collected/never-collected
/// copy and a link to the public privacy policy. Equal-weight affordances — no
/// `.borderedProminent` style bias toward either choice (JC2 dark-pattern check).
///
/// The toggle writes through to `StowerDiagnostics.setEnabled` and the
/// license-record push is the responsibility of the licensing workstream
/// (the `diagnostics_opt_out` field, JC8). Off is one click; no confirmation
/// modal.
internal struct StowerPrivacySettingsView: View {
    @State private var analyticsEnabled: Bool = StowerDiagnostics.isEnabled()

    private static let privacyPolicyURL = URL(string: "https://stower.app/privacy")

    internal var body: some View {
        Form {
            Section {
                Toggle(isOn: consentBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share anonymous usage analytics")
                            .font(.body)
                        Text(
                            analyticsEnabled
                                ? "Anonymous event names and coarse buckets only. Messages, photos,"
                                    + " contacts, file paths, and search text are never sent."
                                : "Analytics off — no usage data will be sent."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Analytics & Crash Reporting")
            }

            Section {
                Text(
                    "Usage stats are anonymous by design. Crash reports are personal-data-scrubbed"
                        + " before sending."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if let url = Self.privacyPolicyURL {
                    Link("Privacy Policy", destination: url)
                        .font(.callout)
                }
                Text(
                    "Stower is open source. You can verify exactly what events are collected "
                        + "and what leaves your Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Transparency")
            }
        }
        .formStyle(.grouped)
        .padding()
        // Re-sync the displayed toggle with the live consent state each time the
        // pane appears: consent can flip elsewhere while this view exists (license
        // opt-out reconciliation, the first-run disclosure card), and a `@State`
        // seeded once at init would otherwise show stale. This writes the `@State`
        // DIRECTLY (not through `consentBinding`), so a resync never triggers a
        // spurious `setEnabled` / `markDisclosureShown`.
        .onAppear { analyticsEnabled = StowerDiagnostics.isEnabled() }
    }

    /// The toggle's binding — only a USER flip writes consent through.
    ///
    /// A user flip calls `StowerDiagnostics.setEnabled` and marks the disclosure
    /// shown (an explicit Settings choice supersedes the first-run card, JC7). The
    /// `.onAppear` display-resync updates `analyticsEnabled` directly and never fires
    /// this setter — so refreshing the view can't re-enable consent or re-mark the card.
    private var consentBinding: Binding<Bool> {
        Binding(
            get: { analyticsEnabled },
            set: { newValue in
                analyticsEnabled = newValue
                StowerDiagnostics.setEnabled(newValue)
                StowerDiagnosticsConsent().markDisclosureShown()
            }
        )
    }
}
