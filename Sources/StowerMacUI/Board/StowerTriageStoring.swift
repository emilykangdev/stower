import Foundation

/// One active dismissal in app-owned terms: which message, and its anchor time.
///
/// The app-owned mirror of the engine's `StowerDismissedMessageRecord`, adapted at
/// the composition seam so the view/board layer never imports `StowerMessages`. The
/// `anchorTimestamp` is the self-expiry discriminator: a dismissed row returns only
/// when the conversation's current last message is STRICTLY newer than it.
internal struct StowerDismissedAnchor: Sendable, Equatable {
    /// The dismissed last act's GUID (its identity, never the expiry test).
    internal let messageGUID: String

    /// The dismissed act's timestamp; the strictly-newer self-expiry anchor.
    internal let anchorTimestamp: Date
}

/// The app-owned boundary the board reads/writes triage (dismiss + mute) through.
///
/// Mirrors how `StowerDraftStoring` fronts the precious `StowerDraftStore`: the
/// board/view layer depends on this app-owned protocol, and the composition adapts
/// the precious `StowerMessages.StowerTriageStore` to it, so the consumers stay free
/// of the engine import (precheck 6b) while durability lives in the data layer.
///
/// Keys are the normalized handle key (`StowerDraftKey`, carried on the row as
/// `draftKey`), never `chatID` — so triage survives an SMS<->iMessage transport flip.
internal protocol StowerTriageStoring: Sendable {
    /// Every active dismissal, keyed by `handleKey` (one row per person).
    func dismissedMessages() async throws -> [String: StowerDismissedAnchor]

    /// The set of muted handle keys.
    func muted() async throws -> Set<String>

    /// Dismisses (or re-dismisses) a person's current last act — upsert by handle.
    func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws

    /// Reverses a dismissal (undo / ⌘Z): deletes the active row, logs nothing.
    func undismiss(handleKey: String) async throws

    /// Retires a dismissal a strictly-newer message superseded — a guarded MOVE into
    /// the append-only history. Idempotent: a stale/concurrent retire is a no-op.
    func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async throws

    /// Mutes a contact (durable; hidden from the board until unmuted).
    func mute(handleKey: String, at: Date) async throws

    /// Unmutes a contact.
    func unmute(handleKey: String, at: Date) async throws
}

/// A volatile triage store for previews and tests ONLY.
///
/// Never used in production (the composition opens the precious on-disk
/// `StowerTriageStore`): a volatile store would silently lose triage intent. It
/// models only the bounded current state the board filter reads — the append-only
/// histories are the on-disk store's concern, verified in `StowerTriageStoreTests`.
internal actor StowerInMemoryTriageStore: StowerTriageStoring {
    private var dismissed: [String: StowerDismissedAnchor]
    private var mutedKeys: Set<String>

    /// Creates an in-memory triage store, optionally pre-seeded.
    internal init(
        dismissed: [String: StowerDismissedAnchor] = [:],
        muted: Set<String> = []
    ) {
        self.dismissed = dismissed
        self.mutedKeys = muted
    }

    internal func dismissedMessages() -> [String: StowerDismissedAnchor] {
        dismissed
    }

    internal func muted() -> Set<String> {
        mutedKeys
    }

    internal func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) {
        dismissed[handleKey] = StowerDismissedAnchor(
            messageGUID: messageGUID,
            anchorTimestamp: anchorTimestamp
        )
    }

    internal func undismiss(handleKey: String) {
        dismissed[handleKey] = nil
    }

    internal func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) {
        // Guarded like the on-disk MOVE: only retire the row still matching this exact
        // anchor, so a stale/concurrent retire (or a newer dismiss) is a clean no-op.
        guard let anchor = dismissed[handleKey],
            anchor.messageGUID == messageGUID,
            anchor.anchorTimestamp == anchorTimestamp
        else {
            return
        }
        dismissed[handleKey] = nil
    }

    internal func mute(handleKey: String, at: Date) {
        mutedKeys.insert(handleKey)
    }

    internal func unmute(handleKey: String, at: Date) {
        mutedKeys.remove(handleKey)
    }
}
