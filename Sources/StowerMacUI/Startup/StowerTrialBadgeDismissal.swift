import Foundation

/// The persistence seam for the trial-badge dismissal flag.
///
/// Writing `true` via `dismiss()` persists across launches; `isDismissed` reads
/// back that value. The flag controls only the badge's presentation — it is never
/// read by the license gate or startup model and does not affect the warranted
/// `.trialExpired` screen (I3).
///
/// Production conformer: `StowerUserDefaultsBadgeDismissal`. Tests inject
/// `StowerInMemoryBadgeDismissal`.
internal protocol StowerTrialBadgeDismissing: Sendable {
    /// Whether the badge has been dismissed by the user.
    var isDismissed: Bool { get }

    /// Marks the badge as dismissed; persists across launches.
    func dismiss()
}

/// A `UserDefaults`-backed `StowerTrialBadgeDismissing`.
///
/// Keyed with `StowerUserDefaultsBadgeDismissal.dismissedKey` in the suite
/// provided at init (`UserDefaults.standard` in production). The key is
/// implementation-private; tests inject an in-memory fake instead.
///
/// `UserDefaults` is not formally `Sendable`, but its `bool(forKey:)` and
/// `set(_:forKey:)` calls are thread-safe for simple scalar reads and writes,
/// which is all this type needs; hence `@unchecked Sendable`.
internal struct StowerUserDefaultsBadgeDismissal: StowerTrialBadgeDismissing, @unchecked Sendable {
    private let defaults: UserDefaults

    /// Creates a dismissal store backed by `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to use; defaults to
    ///   `.standard`.
    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    internal var isDismissed: Bool {
        defaults.bool(forKey: Self.dismissedKey)
    }

    internal func dismiss() {
        defaults.set(true, forKey: Self.dismissedKey)
    }

    /// The `UserDefaults` key that stores the dismissal flag.
    internal static let dismissedKey = "StowerTrialBadgeDismissed"
}
