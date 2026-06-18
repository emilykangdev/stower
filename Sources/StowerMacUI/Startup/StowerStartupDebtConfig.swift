import Foundation

/// The app-owned debt-board knobs the startup flow passes to the provider.
///
/// A thin, distinctly-named copy of the engine's `StowerDebtConfig` (the same
/// three fields) so the views never import the engine; the adapter's `mapConfig`
/// translates this into the engine type 1:1.
internal struct StowerStartupDebtConfig: Sendable, Equatable {
    /// Minimum whole days since the last act before a conversation qualifies.
    internal var unansweredForDays: Int

    /// Minimum recent reciprocal exchanges for a thread to count as two-way.
    internal var minimumReciprocity: Int

    /// Ghosted gate floor: a row needs a should-respond verdict at confidence >= this.
    internal var ghostGateThreshold: Double

    /// Creates an app-owned debt-board configuration.
    ///
    /// `minimumReciprocity` and `ghostGateThreshold` mirror the engine's own init
    /// defaults; `unansweredForDays` has none and must be supplied.
    internal init(
        unansweredForDays: Int,
        minimumReciprocity: Int = 1,
        ghostGateThreshold: Double = 0.5
    ) {
        self.unansweredForDays = unansweredForDays
        self.minimumReciprocity = minimumReciprocity
        self.ghostGateThreshold = ghostGateThreshold
    }

    /// The app default debt configuration.
    ///
    /// `unansweredForDays` has no engine default — the debt threshold ("haven't
    /// replied in N days") is a product knob, so the app supplies it (JC4: 3
    /// days). Emily can change this in one line.
    internal static let appDefault = StowerStartupDebtConfig(unansweredForDays: 3)
}
