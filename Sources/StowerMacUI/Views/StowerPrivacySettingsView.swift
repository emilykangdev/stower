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
                Toggle(isOn: $analyticsEnabled) {
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
                .onChange(of: analyticsEnabled) { _, newValue in
                    StowerDiagnostics.setEnabled(newValue)
                    // An explicit Settings choice supersedes the first-run
                    // disclosure card, so an opted-out user is never re-prompted
                    // (and can't accidentally re-enable via the card). (JC7)
                    StowerDiagnosticsConsent().markDisclosureShown()
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
    }
}
