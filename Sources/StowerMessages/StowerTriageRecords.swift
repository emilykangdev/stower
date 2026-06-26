import Foundation

/// One active dismissal's payload: which message was dismissed and when it landed.
///
/// Returned (keyed by `handleKey`) from `StowerTriageStore.dismissedMessages` so the
/// board filter can test self-expiry: a dismissed row returns only once a STRICTLY
/// newer message arrives (`current.lastMessageTimestamp > anchorTimestamp`). The
/// `handleKey` is the dictionary key, so it is not repeated here. The GUID is the
/// dismissed message's identity (training history + safe concurrent retire), NEVER
/// the expiry test — an edit/unsend can change the GUID without a new message.
public struct StowerDismissedMessageRecord: Sendable, Equatable {
    /// The GUID of the dismissed last act (identity, not the expiry key).
    public let messageGUID: String

    /// The dismissed act's timestamp; the strictly-newer self-expiry discriminator.
    public let anchorTimestamp: Date

    /// Creates a dismissed-message record.
    ///
    /// - Parameters:
    ///   - messageGUID: The dismissed last act's GUID.
    ///   - anchorTimestamp: The dismissed act's timestamp (the self-expiry anchor).
    public init(messageGUID: String, anchorTimestamp: Date) {
        self.messageGUID = messageGUID
        self.anchorTimestamp = anchorTimestamp
    }
}

/// One muted contact's payload: the handle key and when it was last muted.
///
/// Returned from `StowerTriageStore.muted`. Mute is per-handle and durable: a muted
/// handle is hidden from the board regardless of any newer message, until the user
/// unmutes it. `mutedAt` orders the Muted Senders surface; the filter reads only the
/// set of keys.
public struct StowerMutedContactRecord: Sendable, Equatable {
    /// The normalized handle key (`StowerDraftKey`) that is muted.
    public let handleKey: String

    /// When the handle was last muted (a re-mute refreshes it).
    public let mutedAt: Date

    /// Creates a muted-contact record.
    ///
    /// - Parameters:
    ///   - handleKey: The normalized handle key that is muted.
    ///   - mutedAt: When the handle was last muted.
    public init(handleKey: String, mutedAt: Date) {
        self.handleKey = handleKey
        self.mutedAt = mutedAt
    }
}
