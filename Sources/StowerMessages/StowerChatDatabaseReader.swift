import Foundation

/// Reads a validated, read-only snapshot of the local Messages Source DB.
public actor StowerChatDatabaseReader {
    private let snapshot: StowerChatSnapshot
    private let contacts: StowerContactsResolver

    /// The Messages database's file name inside the granted folder.
    ///
    /// The one new public surface this type exposes so app-owned UI code (the
    /// `NSOpenPanel`-driven access picker) can validate a selected folder
    /// contains the right file without hardcoding the literal itself.
    public static let databaseFileName = "chat.db"

    /// Creates a reader over a security-scoped bookmark for the Messages folder.
    ///
    /// - Parameters:
    ///   - loadMessagesAccessBookmark: Reads the currently stored bookmark
    ///     `Data`, or `nil` if none has ever been granted. Invoked once, at
    ///     init — callers re-invoke this initializer (via `readerFactory()`) to
    ///     pick up a bookmark granted after a previous attempt failed.
    ///   - contactsResolver: The handle-to-name resolver; denial degrades to
    ///     raw handles, never an error.
    ///   - onBookmarkRefreshed: Called with freshly re-created bookmark `Data`
    ///     when the stored bookmark resolved but was stale. The engine never
    ///     persists this itself — persistence is the UI's responsibility.
    ///   - resolveBookmark: Resolves bookmark `Data` to a URL and its
    ///     staleness flag. Defaults to the real `URL(resolvingBookmarkData:)`
    ///     call; injectable so staleness/failure paths are deterministically
    ///     testable.
    /// - Throws: `StowerMessagesError.messagesAccessMissing` when no bookmark
    ///   is stored, or the stored bookmark cannot be resolved.
    public init(
        loadMessagesAccessBookmark: @Sendable () -> Data?,
        contactsResolver: StowerContactsResolver = .live(),
        onBookmarkRefreshed: @escaping @Sendable (Data) -> Void = { _ in },
        resolveBookmark: (Data) throws -> (url: URL, isStale: Bool) = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
    ) throws {
        guard let bookmark = loadMessagesAccessBookmark() else {
            throw StowerMessagesError.messagesAccessMissing("no Messages folder selected yet")
        }
        guard let resolved = try? resolveBookmark(bookmark) else {
            throw StowerMessagesError.messagesAccessMissing(
                "stored Messages access could not be resolved"
            )
        }
        if resolved.isStale {
            // .securityScopeAllowOnlyReadAccess matches the app's read-only
            // files.user-selected entitlement (Codex finding, ship-with-codex
            // iter 2) — .withSecurityScope alone is documented by Apple to
            // grant read/write on resolution, which the entitlement can't
            // actually honor.
            //
            // Re-creating a bookmark from an already-resolved security-scoped
            // URL itself counts as "using" the scoped resource, not merely
            // reading its contents — without an active start/stop bracket this
            // throws NSCocoaErrorDomain Code=256 ("Could not open() the item"),
            // which `try?` was silently swallowing, so the self-heal never
            // actually persisted a refreshed bookmark (Cursor Bugbot finding).
            let didStartScope = resolved.url.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
            }
            let refreshedBookmark = try? resolved.url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            if let refreshedBookmark {
                onBookmarkRefreshed(refreshedBookmark)
            }
        }
        let resolvedURL = resolved.url
        snapshot = try StowerChatSnapshot(
            sourceURL: resolvedURL.appendingPathComponent(Self.databaseFileName),
            startAccessingScope: { resolvedURL.startAccessingSecurityScopedResource() },
            stopAccessingScope: { resolvedURL.stopAccessingSecurityScopedResource() }
        )
        contacts = contactsResolver
    }

    #if DEBUG
        /// Creates a reader directly over `demoSourceURL`, bypassing the
        /// bookmark/security-scope machinery entirely.
        ///
        /// DEBUG-only: lets demo/dev builds point at a curated database (e.g.
        /// `Scripts/generate-demo-db.py`'s output) without a picker or a real
        /// grant. Never compiled into a Release build.
        public init(
            demoSourceURL: URL,
            contactsResolver: StowerContactsResolver = .live()
        ) throws {
            snapshot = try StowerChatSnapshot(sourceURL: demoSourceURL)
            contacts = contactsResolver
        }
    #endif

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
    ///   `windowDays`, or `.unreadableSource` if a snapshot read fails. Missing
    ///   Messages access is surfaced earlier, at `init`, as
    ///   `.messagesAccessMissing`.
    public func conversationStates(
        windowDays: Int = 180,
        now: Date = Date()
    ) throws -> [StowerConversationState] {
        try conversationStateRecords(windowDays: windowDays, now: now).map(\.state)
    }

    /// Returns per-1:1 facts paired with each conversation's last-act GUID.
    ///
    /// The GUID feeds the verdict cache key; it never reaches the public
    /// `StowerConversationState.init`. Same window/error semantics as
    /// `conversationStates`.
    ///
    /// - Throws: `StowerMessagesError.invalidArgument` for a negative
    ///   `windowDays`, or `.unreadableSource` if a snapshot read fails. Missing
    ///   Messages access is surfaced earlier, at `init`, as
    ///   `.messagesAccessMissing`.
    internal func conversationStateRecords(
        windowDays: Int = 180,
        now: Date = Date()
    ) throws -> [StowerConversationStateRecord] {
        guard windowDays >= 0 else {
            throw StowerMessagesError.invalidArgument("Window days must not be negative.")
        }
        let startDate = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let items = try ingestWindow(days: windowDays, now: now)
        let activity = try snapshot.activityRows(since: startDate)
        let reactions = try snapshot.reactionRows(since: startDate)
        return StowerConversationStateExtractor.records(
            items: items,
            activity: activity,
            reactions: reactions,
            contacts: contacts,
            now: now
        )
    }

    /// Returns the newest messages of one chat as lightweight thread rows.
    ///
    /// Mirrors `recentMessages` but yields `StowerThreadMessage` (carrying a
    /// per-message `kind`) for the tap-through thread view. The body is decoded
    /// for text/link rows and `nil` for any other kind. Ordered oldest-first for
    /// display. A `limit <= 0` yields no rows.
    public func threadMessages(
        chatID: String,
        limit: Int = 100
    ) throws -> [StowerThreadMessage] {
        guard limit > 0 else {
            return []
        }
        let sourceRows = try snapshot.threadRows(chatID: chatID, limit: limit)
        var seenGUIDs: Set<String> = []
        let rows = sourceRows.compactMap { row -> StowerThreadMessage? in
            guard seenGUIDs.insert(row.guid).inserted,
                let timestamp = StowerMessageDate.date(from: row.rawDate)
            else {
                return nil
            }
            return threadMessage(for: row, timestamp: timestamp)
        }
        return rows.reversed()
    }

    private func threadMessage(
        for row: StowerSourceMessageRow,
        timestamp: Date
    ) -> StowerThreadMessage {
        let hasText = row.text != nil || row.attributedBody != nil
        let kind = StowerConversationStateExtractor.classifyKind(
            balloonBundleID: row.balloonBundleID,
            hasText: hasText,
            hasAttachments: row.hasAttachments
        )
        let text = (kind == .text || kind == .link) ? decodedBody(for: row) : nil
        return StowerThreadMessage(
            id: row.guid,
            isFromMe: row.isFromMe,
            timestamp: timestamp,
            text: text,
            kind: kind
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
