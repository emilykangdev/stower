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
    internal var showsContactsAccessBanner: Bool {
        phase == .rows && contactsAuthorization != .authorized
    }

    /// The banner button's label, matched to the action `resolveContactsAccess` will
    /// take: a never-asked board can be prompted in-app; a denied one must go to
    /// Settings; a wedged request (`contactsRequestTimedOut` — see
    /// `Docs/Permissions.md`) can only be retried in-app too, since the request
    /// never reached `tccd` and Stower was never listed in Settings to begin with.
    internal var contactsBannerActionTitle: String {
        switch contactsAuthorization {
        case .denied: return "Open Settings"
        case .notDetermined where contactsRequestTimedOut: return "Try Again"
        default: return "Show names"
        }
    }

    /// Drives the banner's button: raise the system prompt, or route to Settings.
    ///
    /// `.notDetermined` raises the one system prompt and reloads on a fresh grant
    /// (in-flight re-taps ignored); `.denied`/restricted can't be re-prompted, so it
    /// opens System Settings → Contacts and arms a recovery reload for when the user
    /// returns (`onAppBecameActive`); `.authorized` is a no-op.
    ///
    /// The system prompt itself can wedge on this machine's permission state
    /// (`Docs/Permissions.md`) — that surfaces here as a thrown `.timedOut`,
    /// which releases `isRequestingContacts` and relabels the banner "Try Again"
    /// instead of leaving it silently dead forever. Settings is deliberately NOT
    /// offered on timeout: the request never reached the OS permission broker,
    /// so Stower isn't listed there to grant. A genuinely late answer (the user
    /// was just slow to tap Allow) still lands via `onLateResult` rather than
    /// being discarded.
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
                do {
                    let granted = try await contacts.requestAccessIfNeeded { [weak self] in
                        self?.applyContactsOutcome($0)
                    }
                    applyContactsOutcome(granted)
                } catch {
                    // requestAccessIfNeeded's only throwing case is the OS call
                    // wedging past the timeout — but this task may have been
                    // cancelled (onDisappear) while waiting on it, in which case
                    // the board is gone and this is not a real timeout the user
                    // ever saw. Checking `contactsTask` (the outer task's own
                    // handle) rather than the ambient `Task.isCancelled` matters
                    // here too — see `applyContactsOutcome`.
                    guard contactsTask?.isCancelled != true else { return }
                    contactsRequestTimedOut = true
                    syncContactsAuthorization()
                }
            }
        }
    }

    /// Applies a grant/deny outcome — including one that arrives late, after
    /// `resolveContactsAccess` already gave up and threw `.timedOut` — by
    /// refreshing the observed status and reloading into names on a grant.
    ///
    /// A late outcome runs on `StowerContactsAccess`'s own unstructured
    /// tracking task, not on `contactsTask` — the ambient `Task.isCancelled`
    /// there would always read `false` regardless of whether the board was
    /// torn down, silently letting a stale grant reload it. Checking
    /// `contactsTask?.isCancelled` instead asks the specific outer task the
    /// user's `cancel()` actually cancels.
    ///
    /// A cancelled outcome does nothing at all — not even
    /// `syncContactsAuthorization()` — rather than syncing status without
    /// reloading rows: that would hide the banner while leaving stale
    /// handle-only rows on screen with nothing left to prompt a retry. Safe to
    /// skip entirely: `onAppear`/`onAppBecameActive` already re-sync
    /// authorization (and reload if it changed) the next time the board
    /// becomes relevant again.
    private func applyContactsOutcome(_ granted: Bool) {
        guard contactsTask?.isCancelled != true else { return }
        contactsRequestTimedOut = false
        syncContactsAuthorization()
        guard granted else { return }
        load()
    }

    /// Mirrors the live Contacts authorization into observed state.
    ///
    /// So the banner's visibility and label recompute. Cheap; call it wherever
    /// authorization can move.
    internal func syncContactsAuthorization() {
        contactsAuthorization = contacts.authorization
    }
}
