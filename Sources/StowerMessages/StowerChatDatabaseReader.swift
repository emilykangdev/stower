import Foundation

/// Reads a validated, read-only snapshot of the local Messages Source DB.
public actor StowerChatDatabaseReader {
    private let snapshot: StowerChatSnapshot
    private let contacts: StowerContactsResolver

    /// The default local Messages database location.
    public static var defaultSourceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// Creates a reader and one reusable ephemeral Source DB snapshot.
    public init(
        sourceURL: URL = StowerChatDatabaseReader.defaultSourceURL,
        contactsResolver: StowerContactsResolver = .live()
    ) throws {
        snapshot = try StowerChatSnapshot(sourceURL: sourceURL)
        contacts = contactsResolver
    }

    /// Returns decoded, indexable messages from the most recent window.
    public func ingestWindow(
        days: Int = 180,
        now: Date = Date()
    ) throws -> [StowerMessageItem] {
        guard days >= 0 else {
            throw StowerMessagesError.invalidArgument("Window days must not be negative.")
        }
        let startDate = now.addingTimeInterval(-Double(days) * 86_400)
        let source = try snapshot.ingestRows(since: startDate)
        return mapRows(
            source.rows,
            participants: source.participants,
            reverseForDisplay: false
        )
    }

    /// Returns the newest messages from one chat in chronological display order.
    public func recentMessages(
        chatID: String,
        limit: Int = 100
    ) throws -> [StowerMessageItem] {
        guard limit > 0 else {
            return []
        }
        let source = try snapshot.recentRows(chatID: chatID, limit: limit)
        return mapRows(
            source.rows,
            participants: source.participants,
            reverseForDisplay: true
        )
    }

    /// Returns neutral per-1:1 conversation facts for the recent window.
    ///
    /// One `StowerConversationState` per one-to-one (`directChatStyle`) chat
    /// with any real message in the window; groups never appear. `lastActor`,
    /// `lastMessageKind`, and the timestamps come from the TRUE chronology (any
    /// content type), so a non-text last act is labelled rather than mistaken
    /// for an older text. `counterpart` falls back to the raw handle when
    /// Contacts has no name; `deepLink` is `nil` when no `sms:` link can be
    /// formed.
    ///
    /// - Throws: `StowerMessagesError.invalidArgument` for a negative
    ///   `windowDays`, or `.unreadableSource` if a snapshot read fails. Full
    ///   Disk Access is surfaced earlier, at `init`, as `.fullDiskAccessMissing`.
    public func conversationStates(
        windowDays: Int = 180,
        now: Date = Date()
    ) throws -> [StowerConversationState] {
        guard windowDays >= 0 else {
            throw StowerMessagesError.invalidArgument("Window days must not be negative.")
        }
        let startDate = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let items = try ingestWindow(days: windowDays, now: now)
        let activity = try snapshot.activityRows(since: startDate)
        let reactions = try snapshot.reactionRows(since: startDate)
        return StowerConversationStateExtractor.states(
            items: items,
            activity: activity,
            reactions: reactions,
            contacts: contacts,
            now: now
        )
    }

    /// Returns the 1:1 conversations the user owes a reply to, ranked
    /// most-recently-unanswered first.
    ///
    /// Convenience over `conversationStates` + `StowerNoReplyPolicy`. A
    /// counterpart's non-text last act (photo/sticker) is surfaced with its
    /// `lastMessageKind`, not suppressed. The order is deterministic: newer
    /// unanswered acts first, ties broken by `chatID`. `deepLink` may be `nil`.
    ///
    /// - Parameters:
    ///   - unansweredForDays: Minimum whole days since the counterpart's last
    ///     act (UI presets are days). Must be in `0...windowDays` — a threshold
    ///     beyond the read window could only ever match unread history.
    ///   - minimumReciprocity: Minimum recent reciprocal exchanges for the
    ///     thread to count as a real two-way relationship. Must be `>= 0`.
    ///   - windowDays: How far back to read. Must be `>= 0`.
    ///   - now: The reference instant the age is measured against.
    /// - Returns: The candidates, ranked most-recently-unanswered first.
    /// - Throws: `StowerMessagesError.invalidArgument` for a negative argument or
    ///   an `unansweredForDays` greater than `windowDays`, or `.unreadableSource`
    ///   if a snapshot read fails. Full Disk Access is surfaced earlier, at
    ///   `init`, as `.fullDiskAccessMissing`.
    public func noReplyCandidates(
        unansweredForDays: Int,
        minimumReciprocity: Int = 1,
        windowDays: Int = 180,
        now: Date = Date()
    ) throws -> [StowerNoReplyCandidate] {
        guard unansweredForDays >= 0 else {
            throw StowerMessagesError.invalidArgument("unansweredForDays must not be negative.")
        }
        guard minimumReciprocity >= 0 else {
            throw StowerMessagesError.invalidArgument("minimumReciprocity must not be negative.")
        }
        // A threshold beyond the read window can only match history we never
        // read, so it would silently return zero. Reject it: widen windowDays.
        guard unansweredForDays <= windowDays else {
            throw StowerMessagesError.invalidArgument(
                "unansweredForDays (\(unansweredForDays)) must not exceed windowDays "
                    + "(\(windowDays)); widen the read window to cover the threshold."
            )
        }
        let states = try conversationStates(windowDays: windowDays, now: now)
        return StowerNoReplyPolicy.candidates(
            from: states,
            unansweredForDays: unansweredForDays,
            minimumReciprocity: minimumReciprocity,
            now: now
        )
    }

    private func mapRows(
        _ rows: [StowerSourceMessageRow],
        participants: [Int64: [String]],
        reverseForDisplay: Bool
    ) -> [StowerMessageItem] {
        var seenGUIDs: Set<String> = []
        let items = rows.compactMap { row -> StowerMessageItem? in
            guard seenGUIDs.insert(row.guid).inserted else {
                return nil
            }
            let body = decodedBody(for: row)
            return StowerMessageMapper.map(
                row: row,
                body: body,
                participantHandles: participants[row.chat.rowID] ?? [],
                contacts: contacts
            )
        }
        return reverseForDisplay ? items.reversed() : items
    }

    private func decodedBody(for row: StowerSourceMessageRow) -> String? {
        guard let attributedBody = row.attributedBody else {
            return row.text
        }
        do {
            return try StowerAttributedBodyDecoder.decode(attributedBody) ?? row.text
        } catch {
            return row.text
        }
    }
}
