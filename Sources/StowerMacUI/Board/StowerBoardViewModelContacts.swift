import Foundation

/// The board view-model's Contacts-access surface: the "show real names" banner's
/// visibility/label and the action that raises the system prompt or routes to
/// System Settings.
///
/// Split into this extension (the same split-across-files posture as
/// `StowerDebtBoardProvider`'s mechanics) so the primary file stays focused on the
/// load/refresh state machine. `onAppBecameActive` — which writes the core
/// `phase`/`board`/`contactsRevocationToken` — stays in the primary file so those
/// keep `private(set)`.
extension StowerBoardViewModel {
    /// Whether to show the "show real names" banner above the board.
    ///
    /// Visible exactly when the board has rows to label and Contacts is not
    /// authorized, so an unmatched board always carries a durable way to grant
    /// access. Empty / caught-up / preparing boards show nothing.
    ///
    /// Suppressed in demo mode (DEBUG + `STOWER_MESSAGES_DB`): the injected demo
    /// resolver already fills names in, so the "showing phone numbers" prompt would
    /// contradict the visibly-named rows. `isDemoMode` is injected (live default) so
    /// this stays hermetic — the outcome never depends on the ambient process env.
    /// Always shows normally in Release.
    internal var showsContactsAccessBanner: Bool {
        phase == .rows
            && contactsAuthorization != .authorized
            && !isDemoMode
    }

    /// The banner button's label, matched to the action `resolveContactsAccess` will
    /// take: a never-asked board can be prompted in-app; a denied one must go to
    /// Settings, so the label sets that expectation before the tap.
    internal var contactsBannerActionTitle: String {
        switch contactsAuthorization {
        case .denied: return "Open Settings"
        default: return "Show names"
        }
    }

    /// Drives the banner's button: raise the system prompt, or route to Settings.
    ///
    /// `.notDetermined` raises the one system prompt and reloads on a fresh grant
    /// (in-flight re-taps ignored); `.denied`/restricted can't be re-prompted, so it
    /// opens System Settings → Contacts and arms a recovery reload for when the user
    /// returns (`onAppBecameActive`); `.authorized` is a no-op.
    internal func resolveContactsAccess() {
        switch contacts.authorization {
        case .authorized:
            return
        case .denied:
            awaitingContactsRecovery = true
            settings.openPane(.contacts)
        case .notDetermined:
            guard !isRequestingContacts else { return }
            isRequestingContacts = true
            contactsTask = Task { [weak self] in
                guard let self else { return }
                defer { isRequestingContacts = false }
                let granted = await contacts.requestAccessIfNeeded()
                // Reflect the outcome (grant *or* deny) so the banner updates: a deny
                // flips the label to "Open Settings"; a grant reloads into names.
                syncContactsAuthorization()
                guard granted, !Task.isCancelled else { return }
                load()
            }
        }
    }

    /// Mirrors the live Contacts authorization into observed state.
    ///
    /// So the banner's visibility and label recompute. Cheap; call it wherever
    /// authorization can move.
    internal func syncContactsAuthorization() {
        contactsAuthorization = contacts.authorization
    }
}
