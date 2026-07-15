import SwiftUI

/// The first-run diagnostics consent card, shown after ~60 seconds of foreground
/// board time (JC7 — after value, never at startup or the messages-access cliff).
///
/// Presents the honest, equal-weight consent choice: On · Off. No
/// `.borderedProminent` bias; no "Got it" acknowledgement-as-consent. The card
/// gates diagnostics collection: no Sentry or TelemetryDeck backend starts until
/// the user chooses On.
///
/// Copy is authored in the plan (§What / In-app copy) and reproduced verbatim:
/// headline, body (analytics clause + crash clause), and button labels all
/// sourced from the plan text. The two anonymity guarantees — anonymous-by-design
/// for usage stats, best-effort-scrubbed for crash reports — are disclosed
/// together in one honest card (plan §What / §Copy).
internal struct StowerAnalyticsConsentCard: View {
    /// Called when the user taps a button: `true` to opt in, `false` to opt out.
    ///
    /// The caller writes the choice to `StowerDiagnostics.setEnabled`.
    internal var onChoice: (Bool) -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stower shares anonymous usage stats.")
                .font(.headline)

            Text(
                "To see where setup breaks and what to fix, Stower sends anonymous, "
                    + "coarse usage events (app version, OS version, which step you reached, "
                    + "which features you tap). It never sends your messages, photos, contacts, "
                    + "search text, or file paths — that stays on your Mac. The code is open; "
                    + "you can verify exactly what leaves your machine. "
                    + "Change this anytime in Settings → Privacy."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "If Stower crashes, it also sends a crash report so we can fix it. "
                    + "Crash reports are scrubbed of personal data before they leave your Mac "
                    + "— never your messages, photos, contacts, search text, or file paths."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Spacer()
                // Equal-weight buttons: neither uses .borderedProminent (JC2 /
                // dark-pattern check). The toggle label supplies the context.
                Button("Off") { onChoice(false) }
                    .buttonStyle(.bordered)
                Button("On") { onChoice(true) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
