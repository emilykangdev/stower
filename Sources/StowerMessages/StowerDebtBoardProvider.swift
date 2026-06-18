import Foundation
import os

/// The production `StowerDebtBoardProviding` actor.
///
/// Orchestrates: a startup availability gate → a shared snapshot reader (rebuilt
/// each refresh) → states with last-act GUIDs → trusted cached language-model
/// verdicts → the two policies → a judged-only board. The load path never reaches
/// a model and serves
/// only conversations a trusted verdict is cached for; the background
/// `refreshJudgments` is the only model caller and the only cache writer. The
/// cache is the trust boundary and is disposable — any cache fault is a miss,
/// re-judged later (M9). The judging + timeout mechanics live in the matching
/// `extension` file.
public actor StowerDebtBoardProvider: StowerDebtBoardProviding {
    internal let readerFactory: @Sendable () throws -> StowerConversationFactsReading
    internal let resolveLanguageModelJudge: @Sendable () -> StowerReplyExpectationJudge?
    internal let modelAvailabilityResolver: @Sendable () async -> StowerModelAvailability
    internal let cache: StowerReplyVerdictCaching?
    internal let windowDays: Int
    private var refreshInFlight = false

    /// The shared snapshot reader, reused across loads and thread taps.
    ///
    /// Opening a reader copies `chat.db` and runs a full integrity check — too
    /// expensive to repeat on every board load and every thread tap-through. One
    /// reader is opened lazily and reused; `refreshJudgments` rebuilds it so each
    /// background pass reads current messages. Between refreshes the board is
    /// served from cached verdicts anyway, so reuse adds no staleness the cache
    /// did not already have. The actor serializes access; a failed rebuild keeps
    /// the last good reader.
    private var activeReader: StowerConversationFactsReading?

    /// Per-record cap on one judge call so a hung model can't stall refresh.
    ///
    /// On timeout the record is counted `failed` and retried next pass. Lives on
    /// the provider (its refresh enforces the cap) — not on the `@available`
    /// judge, which the non-gated provider couldn't reference without an
    /// availability dance. Tune to real on-device FM latency.
    internal static let perRecordTimeout: Duration = .seconds(20)

    internal static let logger = Logger(subsystem: "com.stower.messages", category: "reply-refresh")

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
    ///   - cacheURL: Where to persist trusted verdicts; a fault here leaves the
    ///     cache absent and the board empty until refresh can rebuild it (M9).
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
        // Resolve the system judge per call, not once at init: a provider built
        // while Apple Intelligence is still downloading picks the model up when it
        // comes online.
        resolveLanguageModelJudge = { Self.makeSystemLanguageModelJudge() }
        modelAvailabilityResolver = { StowerLanguageModelAvailability.current() }
        cache = cacheURL.flatMap(Self.openCache)
        self.windowDays = windowDays
    }

    /// Creates a provider from injected dependencies, for tests.
    ///
    /// A `languageModelJudgeResolver` models availability changing over time — it
    /// is consulted on each pass. `modelAvailabilityResolver` injects each typed
    /// availability state so tests assert load/refresh route before touching the
    /// reader. Availability is no longer inferred from a nil judge.
    internal init(
        readerFactory: @escaping @Sendable () throws -> StowerConversationFactsReading,
        languageModelJudge: StowerReplyExpectationJudge?,
        cache: StowerReplyVerdictCaching?,
        windowDays: Int = 180,
        languageModelJudgeResolver: (@Sendable () -> StowerReplyExpectationJudge?)? = nil,
        modelAvailabilityResolver: @escaping @Sendable () async -> StowerModelAvailability = {
            .available
        }
    ) {
        self.readerFactory = readerFactory
        resolveLanguageModelJudge = languageModelJudgeResolver ?? { languageModelJudge }
        self.modelAvailabilityResolver = modelAvailabilityResolver
        self.cache = cache
        self.windowDays = windowDays
    }

    /// Whether the on-device language model can serve verdicts right now.
    public func modelAvailability() async -> StowerModelAvailability {
        await modelAvailabilityResolver()
    }

    /// The shared reader, opening one on first use (load / thread-tap path).
    private func sharedReader() throws -> StowerConversationFactsReading {
        if let activeReader {
            return activeReader
        }
        let reader = try readerFactory()
        activeReader = reader
        return reader
    }

    /// Rebuilds the shared reader so a refresh pass reads current messages.
    private func refreshedReader() throws -> StowerConversationFactsReading {
        let reader = try readerFactory()
        activeReader = reader
        return reader
    }

    /// Builds the judged-only board from the shared snapshot plus trusted verdicts.
    public func loadDebtBoard(config: StowerDebtConfig, now: Date) async throws -> StowerDebtBoard {
        // A threshold past the read window could only ever match unread history,
        // so it would silently return an empty board. Fail loud: widen windowDays.
        guard config.unansweredForDays <= windowDays else {
            throw StowerMessagesError.invalidArgument(
                "unansweredForDays (\(config.unansweredForDays)) must not exceed the provider's "
                    + "windowDays (\(windowDays)); widen the read window to cover the threshold."
            )
        }
        // Availability is checked AFTER config bounds but BEFORE the reader, so an
        // unsupported device never opens the private database. A supported device
        // still surfaces FDA / source errors normally.
        if case .unavailable(let reason) = await modelAvailabilityResolver() {
            throw StowerMessagesError.languageModelUnavailable(reason)
        }
        // Resolve the judge BEFORE opening the reader. Availability passed above but
        // the concrete judge could not be built (model evicted between the two
        // resolves, or a construction fault). Fail loud and symmetric with the
        // availability gate — and before the side effect of opening (copying)
        // chat.db — never a silent empty board the user reads as "all caught up".
        guard let judge = resolveLanguageModelJudge() else {
            throw StowerMessagesError.languageModelUnavailable(.modelNotReady)
        }
        let reader = try sharedReader()
        let records = try await reader.conversationStateRecords(windowDays: windowDays, now: now)
        let judged = await judgedConversations(records: records, judge: judge)
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
        let reader = try sharedReader()
        return try await reader.threadMessages(chatID: chatID, limit: limit)
    }

    /// Judges un-cached conversations with the model and backfills the cache.
    public func refreshJudgments(
        config: StowerDebtConfig,
        now: Date
    ) async throws -> StowerRefreshSummary? {
        // Single-flight FIRST, before availability: a coalesced caller always gets
        // `nil`, even if availability changed while a pass was in flight. `nil`
        // means exactly "coalesced" — never a `0/0/0` that would clear loading.
        guard !refreshInFlight else { return nil }
        refreshInFlight = true
        defer { refreshInFlight = false }

        // Re-resolved each (non-coalesced) pass so a mid-session change (AI turned
        // off, model downloading) throws and the app re-routes — never a silent
        // no-op. Symmetric with `loadDebtBoard`.
        if case .unavailable(let reason) = await modelAvailabilityResolver() {
            throw StowerMessagesError.languageModelUnavailable(reason)
        }
        // Pre-loop cancellation (before `totalCount` exists) has no meaningful
        // partial summary, so it propagates via `throws`.
        try Task.checkCancellation()

        let reader = try refreshedReader()
        let records = try await reader.conversationStateRecords(windowDays: windowDays, now: now)

        // First-run ABSENCE is created at init (the file is made on open); only a
        // create/open FAILURE — or a `cacheURL: nil` no-cache config — leaves
        // `cache == nil`, in which case no trusted verdict can ever persist. Report
        // all-failed so loading clears and the next pass may rebuild the cache.
        guard let cache, let judge = resolveLanguageModelJudge() else {
            return StowerRefreshSummary(
                changedChatIDs: [],
                judgedCount: 0,
                failedCount: records.count,
                totalCount: records.count
            )
        }
        return await runRefreshPass(records: records, judge: judge, cache: cache)
    }

    internal static func makeSystemLanguageModelJudge() -> StowerReplyExpectationJudge? {
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
    /// return `nil` only if recreation also fails (then refresh reports all-failed
    /// and the next provider may rebuild it).
    ///
    /// The rebuild deletes the file and its WAL/shm sidecars, so it runs only for a
    /// path named like our own cache. A caller-supplied `cacheURL` pointing at
    /// unrelated SQLite data must never be clobbered on open failure.
    internal static func openCache(at url: URL) -> StowerReplyVerdictCaching? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let cache = try? StowerReplyVerdictCache(path: url.path) {
            return cache
        }
        guard url.lastPathComponent == StowerReplyVerdictCache.fileName else {
            return nil
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return try? StowerReplyVerdictCache(path: url.path)
    }
}
