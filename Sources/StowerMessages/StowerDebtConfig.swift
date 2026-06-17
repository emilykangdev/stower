import Foundation

/// The per-call knobs for one debt-board computation.
///
/// Per-call, not stateful: a runtime filter flip (`unansweredForDays`,
/// `ghostGateThreshold`) re-runs only the gate and rank over the cached verdicts
/// and structural facts — it never re-invokes the model. The read window is a
/// provider-construction concern, not a per-call knob.
public struct StowerDebtConfig: Sendable {
    /// Minimum whole days since the last act before a conversation qualifies.
    public var unansweredForDays: Int

    /// Minimum recent reciprocal exchanges for a thread to count as two-way.
    public var minimumReciprocity: Int

    /// Ghosted gate floor: a row needs `expectsReply && confidence >= this`.
    ///
    /// The default reproduces the binary gate on the model path (a confident
    /// should-respond passes, a confident non-ask gates out) and tunes how
    /// aggressively the noisier "you sent last" lens admits graded asks.
    public var ghostGateThreshold: Double

    /// Creates a debt-board configuration.
    public init(
        unansweredForDays: Int,
        minimumReciprocity: Int = 1,
        ghostGateThreshold: Double = 0.5
    ) {
        self.unansweredForDays = unansweredForDays
        self.minimumReciprocity = minimumReciprocity
        self.ghostGateThreshold = ghostGateThreshold
    }
}
