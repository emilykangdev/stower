import Foundation

/// The verdict-resolution, refresh-pass, and per-record-timeout mechanics behind
/// `StowerDebtBoardProvider`. Split out so the actor file stays the orchestration
/// surface and this file owns the trust + judging detail.
extension StowerDebtBoardProvider {
    // MARK: - Load path (never calls the model)

    internal func judgedConversations(
        records: [StowerConversationStateRecord],
        judge: StowerReplyExpectationJudge
    ) async -> [StowerJudgedConversation] {
        guard let cache else { return [] }
        let version = judge.judgeVersion(modelIdentity: modelIdentity)
        var result: [StowerJudgedConversation] = []
        result.reserveCapacity(records.count)
        for record in records {
            let verdict: StowerReplyExpectation?
            do {
                verdict = try await cache.existing(
                    judgeVersion: version,
                    guid: record.lastMessageGUID,
                    inputHash: inputHash(for: record.state)
                )
            } catch {
                // The disposable cache faulted: disable it for this load. Remaining
                // records are misses (excluded), never blocked (M9).
                break
            }
            guard let verdict, isTrustedVerdict(verdict) else {
                continue  // a miss / non-trusted / invalid verdict is unjudged → excluded
            }
            result.append(StowerJudgedConversation(state: record.state, verdict: verdict))
        }
        return result
    }

    // MARK: - Refresh path (the only model caller)

    internal func runRefreshPass(
        records: [StowerConversationStateRecord],
        judge: StowerReplyExpectationJudge,
        cache: StowerReplyVerdictCaching
    ) async -> StowerRefreshSummary {
        let version = judge.judgeVersion(modelIdentity: modelIdentity)
        // Judge most-recently-active threads FIRST so the conversations the user
        // is most likely looking at get a verdict soonest.
        let ordered = records.sorted {
            $0.state.lastMessageTimestamp > $1.state.lastMessageTimestamp
        }
        let split = await classify(ordered: ordered, version: version, cache: cache)
        var tally = StowerRefreshTally(judged: split.judged)
        judgeLoop: for record in split.needing {
            // Parent-cancelled BEFORE the call → uncounted (`judged+failed < total`).
            if Task.isCancelled { break judgeLoop }
            switch await judgeRecord(record, judge: judge, cache: cache, version: version) {
            case .cancelled:
                break judgeLoop  // parent cancel DURING the call → uncounted (NOT failed)
            case .judged(let chatID):
                tally.judged += 1
                tally.changed.append(chatID)
            case .timedOut:
                tally.failed += 1
                tally.timeouts += 1
            case .writeFailed:
                tally.failed += 1
                tally.writeFails += 1
            case .failed:
                tally.failed += 1
            }
        }
        Self.logRefresh(tally, total: records.count)
        return StowerRefreshSummary(
            changedChatIDs: tally.changed,
            judgedCount: tally.judged,
            failedCount: tally.failed,
            totalCount: records.count
        )
    }

    /// Splits the snapshot into already-judged (trusted cache hits) and the rest.
    private func classify(
        ordered: [StowerConversationStateRecord],
        version: String,
        cache: StowerReplyVerdictCaching
    ) async -> (judged: Int, needing: [StowerConversationStateRecord]) {
        var judged = 0
        var needing: [StowerConversationStateRecord] = []
        for record in ordered {
            if let hit = try? await cache.existing(
                judgeVersion: version,
                guid: record.lastMessageGUID,
                inputHash: inputHash(for: record.state)
            ), isTrustedVerdict(hit) {
                judged += 1
            } else {
                needing.append(record)
            }
        }
        return (judged, needing)
    }

    /// Judges one record under the per-record timeout and persists a trusted
    /// verdict, returning how it resolved.
    private func judgeRecord(
        _ record: StowerConversationStateRecord,
        judge: StowerReplyExpectationJudge,
        cache: StowerReplyVerdictCaching,
        version: String
    ) async -> StowerRefreshRecordOutcome {
        // A counterpart attachment carries no text the model can read, but a sent
        // photo/file plainly invites a reply — so a deterministic rule, not the
        // model, supplies the should-respond signal (and skips a wasted model call).
        if let deterministic = Self.deterministicVerdict(for: record.state) {
            return await persist(deterministic, for: record, cache: cache, version: version)
        }
        let input = record.state.lastMessageText
        switch await stowerJudgeWithTimeout(
            Self.perRecordTimeout,
            { try await judge.judge(messageText: input, context: []) }
        ) {
        case .parentCancelled:
            return .cancelled
        case .timeout:
            return .timedOut
        case .operationFailed:
            return .failed
        case .success(let verdict):
            guard isTrustedVerdict(verdict) else {
                return .failed  // produced a result, but non-trusted / invalid → failed
            }
            return await persist(verdict, for: record, cache: cache, version: version)
        }
    }

    /// Persists a trusted verdict to the cache, mapping a write fault to an outcome.
    private func persist(
        _ verdict: StowerReplyExpectation,
        for record: StowerConversationStateRecord,
        cache: StowerReplyVerdictCaching,
        version: String
    ) async -> StowerRefreshRecordOutcome {
        do {
            try await cache.upsert(
                judgeVersion: version,
                guid: record.lastMessageGUID,
                inputHash: inputHash(for: record.state),
                verdict: verdict
            )
            return .judged(record.state.chatID)
        } catch {
            return .writeFailed
        }
    }

    // MARK: - Trust + hashing

    /// Confidence assigned to a deterministic non-text-content verdict.
    ///
    /// The rule is certain the attachment invites a reply, so `1.0`. Only the
    /// counterpart's last act gets this verdict, which the Neglected lens reads by
    /// boolean alone (it ignores confidence), so the value never tips the
    /// confidence-gated Ghosted lens; it is set honestly rather than left magic.
    internal static let nonTextContentConfidence = 1.0

    /// A trusted verdict for a last act the text model can't read, or `nil`.
    ///
    /// Scoped to a counterpart-sent attachment (photo, file, voice note, video,
    /// sticker): it has no text for the model, but plainly invites a reply, so it
    /// must be eligible for the Neglected lens rather than silently dropped. User
    /// -sent attachments are left to the model path (they stay out of the noisier
    /// Ghosted lens); the policies still gate by reciprocity, recency, and tapback.
    internal static func deterministicVerdict(
        for state: StowerConversationState
    ) -> StowerReplyExpectation? {
        guard state.lastActor == .counterpart, state.lastMessageKind == .attachment else {
            return nil
        }
        return StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: nonTextContentConfidence,
            verdictSource: .nonTextContent
        )
    }

    /// Whether a cached verdict is trusted to reach the board.
    ///
    /// A trusted source with finite `0...1` confidence — one definition, load and
    /// refresh.
    internal func isTrustedVerdict(_ verdict: StowerReplyExpectation) -> Bool {
        verdict.verdictSource.isTrustedVerdictSource
            && verdict.replyExpectationConfidence.isFinite
            && (0...1).contains(verdict.replyExpectationConfidence)
    }

    /// Hashes the cache-validity inputs (M11): the RAW last text the judge
    /// receives plus the kind discriminator.
    ///
    /// Hashing the same text the judge sees (not a trimmed/lowercased copy) is
    /// what makes a case-only edit miss the cache and re-judge. Context is empty
    /// in v1, so it adds no component. The kind uses `rawValue`, a stable
    /// serialization token, so the persisted key can't silently drift the way
    /// `String(describing:)` could across a case rename or compiler change.
    internal func inputHash(for state: StowerConversationState) -> String {
        stowerShortHash(
            (state.lastMessageText ?? "") + "\u{1}" + state.lastMessageKind.rawValue
        )
    }

    private static func logRefresh(_ tally: StowerRefreshTally, total: Int) {
        logger.debug(
            """
            refresh pass complete \
            judged=\(tally.judged, privacy: .public) \
            failed=\(tally.failed, privacy: .public) \
            total=\(total, privacy: .public) \
            timeout=\(tally.timeouts, privacy: .public) \
            writeFail=\(tally.writeFails, privacy: .public)
            """
        )
    }
}

/// How one record resolved in a refresh pass.
private enum StowerRefreshRecordOutcome {
    case judged(String)  // chatID
    case timedOut
    case writeFailed
    case failed
    case cancelled
}

/// Running totals for a single refresh pass.
private struct StowerRefreshTally {
    fileprivate var judged: Int
    fileprivate var failed = 0
    fileprivate var changed: [String] = []
    fileprivate var timeouts = 0
    fileprivate var writeFails = 0
}

/// The four distinguishable outcomes of a timed judge call.
private enum StowerJudgeOutcome: Sendable {
    /// The judge finished first; the verdict may still be non-trusted/invalid.
    case success(StowerReplyExpectation)

    /// The timeout won; the judge call was cancelled and abandoned → count failed.
    case timeout

    /// The judge threw a non-cancellation error → count failed.
    case operationFailed

    /// The enclosing refresh task was cancelled → break the loop uncounted.
    case parentCancelled
}

/// Races one judge call against a timeout, returning a typed outcome.
///
/// Bounds the serial refresh pass so one hung judge can't stall it: on timeout
/// the operation is cancelled and abandoned. SOUNDNESS — a structured task group
/// can't return while a child still runs, so the timeout only bounds the pass if
/// the operation HONORS cooperative cancellation; FoundationModels' `respond`
/// does (Assumption A7, verified). The outcome is typed rather than a bare
/// `try?`-to-`nil`, which would collapse `.timeout` and `.parentCancelled` and
/// could hang loading at `judged + failed < total`.
private func stowerJudgeWithTimeout(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> StowerReplyExpectation
) async -> StowerJudgeOutcome {
    await withTaskGroup(of: StowerJudgeOutcome.self) { group in
        group.addTask {
            do {
                return .success(try await operation())
            } catch is CancellationError {
                return .parentCancelled
            } catch {
                return .operationFailed
            }
        }
        group.addTask {
            do {
                try await Task.sleep(for: duration)
                return .timeout
            } catch {
                return .parentCancelled
            }
        }
        let first = await group.next() ?? .parentCancelled
        group.cancelAll()
        _ = await group.next()  // drain the loser; its cancellation is cooperative
        return first
    }
}
