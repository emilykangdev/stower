import Foundation

/// One semantic, user-owned interaction event in Stower's append-only event log.
///
/// The first producers are board triage — dismiss a message, mute a sender, unmute a
/// sender — but the shape is deliberately general so later product surfaces can add
/// event types WITHOUT changing the table: `eventType` is a string token (not a
/// closed Swift enum the schema mirrors), and unused columns stay `nil`. This is
/// local-first interaction MEMORY, not view telemetry — only meaningful semantic
/// actions land here, never hover/focus/scroll/window noise.
public struct StowerInteractionEvent: Sendable, Equatable {
    /// The event-shape version persisted with every row, so a future reader can
    /// interpret older rows. v1 for the whole triage spine.
    public static let schemaVersion = 1

    /// The semantic event token, such as `message_dismissed` or `sender_muted`.
    public let eventType: String

    /// When the action happened (caller-supplied, for deterministic ordering/tests).
    public let occurredAt: Date

    /// Who acted: `user` / `agent` / `system`. v1 writes `user`.
    public let actor: String

    /// Where the action originated, such as `board` or `muted_senders`.
    public let surface: String

    /// The normalized handle key the event concerns, or `nil`.
    public let handleKey: String?

    /// The message GUID the event concerns, or `nil` (set for `message_dismissed`).
    public let messageGUID: String?

    /// The draft key the event concerns, or `nil` (reserved; `draftKey == handleKey`).
    public let draftKey: String?

    /// The board tab the action was taken from, or `nil`.
    public let boardTab: String?

    /// Opaque JSON for forward-compatible extra fields; `"{}"` when empty.
    public let metadataJSON: String

    /// The `eventType` token for a single-message dismiss.
    public static let messageDismissedType = "message_dismissed"

    /// The `eventType` token for a sender mute.
    public static let senderMutedType = "sender_muted"

    /// The `eventType` token for a sender unmute.
    public static let senderUnmutedType = "sender_unmuted"

    /// The `actor` token v1 always writes (every event is a direct user action).
    public static let userActor = "user"

    /// The empty `metadataJSON` value.
    public static let emptyMetadata = "{}"

    /// Creates an interaction event from already-resolved fields.
    ///
    /// Prefer the `messageDismissed` / `senderMuted` / `senderUnmuted` factories,
    /// which fix the v1 `eventType` / `actor` tokens; this designated init exists for
    /// the store reader and tests.
    public init(
        eventType: String,
        occurredAt: Date,
        actor: String,
        surface: String,
        handleKey: String?,
        messageGUID: String?,
        draftKey: String?,
        boardTab: String?,
        metadataJSON: String
    ) {
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.actor = actor
        self.surface = surface
        self.handleKey = handleKey
        self.messageGUID = messageGUID
        self.draftKey = draftKey
        self.boardTab = boardTab
        self.metadataJSON = metadataJSON
    }

    /// A `message_dismissed` event (always `surface='board'`, `actor='user'`).
    public static func messageDismissed(
        handleKey: String,
        messageGUID: String,
        boardTab: String,
        occurredAt: Date
    ) -> StowerInteractionEvent {
        StowerInteractionEvent(
            eventType: messageDismissedType,
            occurredAt: occurredAt,
            actor: userActor,
            surface: "board",
            handleKey: handleKey,
            messageGUID: messageGUID,
            draftKey: nil,
            boardTab: boardTab,
            metadataJSON: emptyMetadata
        )
    }

    /// A `sender_muted` event from `surface` (`board` or `muted_senders`).
    public static func senderMuted(
        handleKey: String,
        surface: String,
        occurredAt: Date
    ) -> StowerInteractionEvent {
        StowerInteractionEvent(
            eventType: senderMutedType,
            occurredAt: occurredAt,
            actor: userActor,
            surface: surface,
            handleKey: handleKey,
            messageGUID: nil,
            draftKey: nil,
            boardTab: nil,
            metadataJSON: emptyMetadata
        )
    }

    /// A `sender_unmuted` event from `surface` (`board` or `muted_senders`).
    public static func senderUnmuted(
        handleKey: String,
        surface: String,
        occurredAt: Date
    ) -> StowerInteractionEvent {
        StowerInteractionEvent(
            eventType: senderUnmutedType,
            occurredAt: occurredAt,
            actor: userActor,
            surface: surface,
            handleKey: handleKey,
            messageGUID: nil,
            draftKey: nil,
            boardTab: nil,
            metadataJSON: emptyMetadata
        )
    }
}
