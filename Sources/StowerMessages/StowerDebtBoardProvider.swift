import Foundation

/// The production `StowerDebtBoardProviding` actor.
///
/// Orchestrates: a fresh reader per load (M3) → states with last-act GUIDs →
/// cached language-model or inline heuristic verdicts → the two policies → the
/// board. The load path never reaches a model; only `refreshJudgments` does. The
/// judge is chosen by `judgeMode` and runtime availability, and the cache is
/// disposable — any cache fault degrades to a heuristic board (M9).
public actor StowerDebtBoardProvider: StowerDebtBoardProviding {
    private let readerFactory: @Sendable () throws -> StowerConversationFactsReading
    private let heuristicJudge: StowerReplyExpectationJudge
    private let resolveLanguageModelJudge: @Sendable () -> StowerReplyExpectationJudge?
    private let cache: StowerReplyVerdictCaching?
    private let windowDays: Int
    private var inFlightRefreshKeys: Set<String> = []

    /// The default verdict-cache location under Application Support.
    public static var defaultCacheURL: URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return
            base
            .appendingPathComponent("Stower", isDirectory: true)
            .appendingPathComponent(StowerReplyVerdictCache.fileName)
    }

    /// Creates a provider over the local Messages database.
    ///
    /// - Parameters:
    ///   - sourceURL: The Messages `chat.db` to read.
    ///   - contactsResolver: The handle-to-name resolver; denial degrades to raw
    ///     handles (M4), never an error.
    ///   - cacheURL: Where to persist language-model verdicts; a fault here
    ///     leaves the cache absent and the board heuristic (M9).
    ///   - windowDays: How far back to read facts.
    public init(
        sourceURL: URL = StowerChatDatabaseReader.defaultSourceURL,
        contactsResolver: StowerContactsResolver = .live(),
        cacheURL: URL? = StowerDebtBoardProvider.defaultCacheURL,
        windowDays: Int = 180
    ) {
        readerFactory = {
            try StowerChatDatabaseReader(sourceURL: sourceURL, contactsResolver: contactsResolver)
        }
        heuristicJudge = StowerHeuristicReplyJudge()
        // Resolve the system judge per call, not once at init: a provider built
        // while Apple Intelligence is still downloading picks the model up when it
        // comes online, and stops using it if availability later goes away.
        resolveLanguageModelJudge = { Self.makeSystemLanguageModelJudge() }
        cache = cacheURL.flatMap(Self.openCache)
        self.windowDays = windowDays
    }

    /// Creates a provider from injected dependencies, for tests.
    ///
    /// A `nil` `languageModelJudge` models an unavailable system model (all rows
    /// fall to the heuristic); a spy judge models availability. A
    /// `languageModelJudgeResolver` models availability changing over time — it
    /// is consulted until it first yields a judge, then that judge is cached.
    internal init(
        readerFactory: @escaping @Sendable () throws -> StowerConversationFactsReading,
        heuristicJudge: StowerReplyExpectationJudge = StowerHeuristicReplyJudge(),
        languageModelJudge: StowerReplyExpectationJudge?,
        cache: StowerReplyVerdictCaching?,
        windowDays: Int = 180,
        languageModelJudgeResolver: (@Sendable () -> StowerReplyExpectationJudge?)? = nil
    ) {
        self.readerFactory = readerFactory
        self.heuristicJudge = heuristicJudge
        resolveLanguageModelJudge = languageModelJudgeResolver ?? { languageModelJudge }
        self.cache = cache
        self.windowDays = windowDays
    }

    /// Builds the board from a fresh snapshot plus cached/heuristic verdicts.
    public func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard {
        // A threshold past the read window could only ever match unread history,
        // so it would silently return an empty board. Fail loud: widen windowDays.
        guard config.unansweredForDays <= windowDays else {
            throw StowerMessagesError.invalidArgument(
                "unansweredForDays (\(config.unansweredForDays)) must not exceed the provider's "
                    + "windowDays (\(windowDays)); widen the read window to cover the threshold."
            )
        }
        let reader = try readerFactory()
        let records = try await reader.conversationStateRecords(windowDays: windowDays, now: now)
        let judge = activeLanguageModelJudge(for: config.judgeMode)
        let judged = await judgedConversations(records: records, languageModelJudge: judge)
        let neglected = StowerNoReplyPolicy.neglected(
            from: judged,
            unansweredForDays: config.unansweredForDays,
            minimumReciprocity: config.minimumReciprocity,
            now: now
        )
        let ghosted = StowerGhostedPolicy.ghosted(
            from: judged,
            unansweredForDays: config.unansweredForDays,
            minimumReciprocity: config.minimumReciprocity,
            ghostGateThreshold: config.ghostGateThreshold,
            now: now
        )
        return StowerDebtBoard(neglected: neglected, ghosted: ghosted)
    }

    /// Returns the newest messages of one chat for a tap-through thread view.
    public func recentMessages(chatID: String, limit: Int) async throws -> [StowerThreadMessage] {
        let reader = try readerFactory()
        return try await reader.threadMessages(chatID: chatID, limit: limit)
    }

    /// Judges un-cached conversations with the model and backfills the cache.
    public func refreshJudgments(
        config: StowerDebtConfig,
        now: Date
    ) async -> StowerRefreshSummary {
        guard let judge = activeLanguageModelJudge(for: config.judgeMode), let cache,
            let reader = try? readerFactory(),
            let records = try? await reader.conversationStateRecords(
                windowDays: windowDays,
                now: now
            )
        else {
            return StowerRefreshSummary(changedChatIDs: [])
        }
        // Background, off-hot-path work (the load already painted via cache +
        // heuristic). On-device inference is serial by design — the system model
        // is a single shared resource, and live streaming of partial boards is a
        // v1.1 non-goal. Judge most-recently-active threads FIRST, though, so the
        // conversations the user is most likely looking at get a smart verdict
        // soonest: each verdict is upserted as it lands, so the next load reflects
        // whatever has been judged so far.
        let ordered = records.sorted {
            $0.state.lastMessageTimestamp > $1.state.lastMessageTimestamp
        }
        var changed: [String] = []
        for record in ordered {
            if Task.isCancelled { break }
            if let chatID = await refreshOne(record: record, judge: judge, cache: cache) {
                changed.append(chatID)
            }
        }
        return StowerRefreshSummary(changedChatIDs: changed)
    }

    // MARK: - Load path (never calls the model)

    private func judgedConversations(
        records: [StowerConversationStateRecord],
        languageModelJudge: StowerReplyExpectationJudge?
    ) async -> [StowerJudgedConversation] {
        var result: [StowerJudgedConversation] = []
        result.reserveCapacity(records.count)
        // The cache is disposable (M9): the first read fault disables it for the
        // rest of this load, so a locked or corrupt store can never block the
        // board past a single failed lookup.
        var cacheReadable = languageModelJudge != nil && cache != nil
        for record in records {
            var verdict: StowerReplyExpectation?
            if cacheReadable, let languageModelJudge, let cache {
                do {
                    verdict = try await cache.existing(
                        judgeVersion: languageModelJudge.judgeVersion,
                        guid: record.lastMessageGUID,
                        inputHash: inputHash(for: record.state)
                    )
                } catch {
                    cacheReadable = false
                }
            }
            let resolved: StowerReplyExpectation
            if let verdict {
                resolved = verdict
            } else {
                resolved = await heuristicVerdict(for: record.state)
            }
            result.append(StowerJudgedConversation(state: record.state, verdict: resolved))
        }
        return result
    }

    private func heuristicVerdict(
        for state: StowerConversationState
    ) async -> StowerReplyExpectation {
        let verdict = try? await heuristicJudge.judge(
            messageText: state.lastMessageText,
            context: []
        )
        return verdict
            ?? StowerReplyExpectation(
                expectsReply: false,
                replyExpectationConfidence: 0,
                verdictSource: .heuristic
            )
    }

    // MARK: - Refresh path (the only model caller)

    private func refreshOne(
        record: StowerConversationStateRecord,
        judge: StowerReplyExpectationJudge,
        cache: StowerReplyVerdictCaching
    ) async -> String? {
        let hash = inputHash(for: record.state)
        let key = "\(judge.judgeVersion)\u{1}\(record.lastMessageGUID)\u{1}\(hash)"
        // Claim the key synchronously, before any await, so an overlapping
        // refresh for the same message can't slip past the check (M16).
        guard !inFlightRefreshKeys.contains(key) else { return nil }
        inFlightRefreshKeys.insert(key)
        defer { inFlightRefreshKeys.remove(key) }
        if let existing = try? await cache.existing(
            judgeVersion: judge.judgeVersion,
            guid: record.lastMessageGUID,
            inputHash: hash
        ), existing.verdictSource == .languageModel {
            return nil
        }
        // A model error or cancellation must NOT cache a heuristic verdict under
        // the model's judge version (M13); skip and retry next refresh.
        let verdict = try? await judge.judge(
            messageText: record.state.lastMessageText,
            context: []
        )
        guard let verdict, verdict.verdictSource == .languageModel else {
            return nil
        }
        do {
            try await cache.upsert(
                judgeVersion: judge.judgeVersion,
                guid: record.lastMessageGUID,
                inputHash: hash,
                verdict: verdict
            )
        } catch {
            // The disposable cache (M9) refused the write: don't report a change
            // we didn't persist, or the app reloads to the same heuristic verdict.
            return nil
        }
        return record.state.chatID
    }

    // MARK: - Judge selection + hashing

    private func activeLanguageModelJudge(
        for mode: StowerReplyJudgeMode
    ) -> StowerReplyExpectationJudge? {
        switch mode {
        case .heuristic:
            return nil
        case .languageModel, .automatic:
            // Re-resolve every time so the judge tracks CURRENT availability — it
            // appears when Apple Intelligence comes online and disappears if it
            // goes away again. Availability check + judge construction are cheap
            // and never call the model, so the load path stays structural.
            return resolveLanguageModelJudge()
        }
    }

    /// Hashes the cache-validity inputs (M11): normalized text plus the kind.
    ///
    /// Context is empty in v1, so it adds no component.
    private func inputHash(for state: StowerConversationState) -> String {
        let normalized = (state.lastMessageText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return stowerShortHash(normalized + "\u{1}" + String(describing: state.lastMessageKind))
    }

    private static func makeSystemLanguageModelJudge() -> StowerReplyExpectationJudge? {
        guard StowerLanguageModelAvailability.isAvailable() else {
            return nil
        }
        if #available(macOS 26, iOS 26, *) {
            return StowerFoundationModelReplyJudge()
        }
        return nil
    }

    /// Opens the verdict cache, rebuilding it once if the file is unusable.
    ///
    /// Disposable (M9): a corrupt or unreadable store must be REBUILT, not kept as
    /// a permanently dead cache that silently disables every model verdict for the
    /// provider's lifetime. Drop the file (and its WAL sidecars) and retry once;
    /// fall back to a heuristic-only board only if recreation also fails.
    internal static func openCache(at url: URL) -> StowerReplyVerdictCaching? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let cache = try? StowerReplyVerdictCache(path: url.path) {
            return cache
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return try? StowerReplyVerdictCache(path: url.path)
    }
}
