import Foundation
import StowerMessages

/// The shared, engine-coupled translation table between the `StowerMessages`
/// engine types and the app-owned boundary types.
///
/// One of the four files in `StowerMacUI` that import the engine. Both adapters —
/// `StowerMessagesStartupAdapter` (startup) and `StowerLiveBoardDataSource`
/// (board) — call these maps, so the anti-corruption boundary lives in exactly one
/// place instead of being duplicated. This is the only home for the
/// engine→`StowerStartupFailure` error map.
///
/// Engine types are referenced by their **bare** names (`StowerDebtConfig`, not
/// `StowerMessages.StowerDebtConfig`): the module also exports a top-level
/// `enum StowerMessages`, so qualifying would read as a nested-type lookup and fail
/// to compile. The app-owned types keep distinct `Stower*` names, so there is no
/// collision.
internal enum StowerMessagesMapping {
    /// The total engine→app error map; exhaustive by design, so a new engine case
    /// breaks the build until it is mapped here.
    internal static func mapError(_ error: StowerMessagesError) -> StowerStartupFailure {
        switch error {
        case .messagesAccessMissing(let detail): return .messagesAccessMissing(detail: detail)
        case .languageModelUnavailable(let reason): return .modelUnavailable(mapReason(reason))
        case .sourceNotFound: return .sourceMissing
        case .unreadableSource: return .unreadable
        case .invalidSnapshot, .invalidRow: return .invalidData
        case .invalidArgument: return .invalidConfig
        }
    }

    /// Translates engine availability into the app-owned availability 1:1.
    internal static func mapAvailability(
        _ availability: StowerModelAvailability
    ) -> StowerStartupModelAvailability {
        switch availability {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(mapReason(reason))
        }
    }

    /// Translates the engine model-unavailable reason into the app reason 1:1.
    internal static func mapReason(
        _ reason: StowerModelUnavailableReason
    ) -> StowerStartupModelUnavailableReason {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        case .unknown: return .unknown
        }
    }

    /// Builds the engine config from the app-owned config 1:1 (the three knobs).
    internal static func mapConfig(_ config: StowerStartupDebtConfig) -> StowerDebtConfig {
        StowerDebtConfig(
            unansweredForDays: config.unansweredForDays,
            minimumReciprocity: config.minimumReciprocity,
            ghostGateThreshold: config.ghostGateThreshold
        )
    }

    /// Translates the engine last-act kind into the app-owned mirror 1:1.
    internal static func mapKind(
        _ kind: StowerConversationLastMessageKind
    ) -> StowerLastMessageKind {
        switch kind {
        case .text: return .text
        case .link: return .link
        case .attachment: return .attachment
        case .app: return .app
        case .other: return .other
        }
    }

    /// Maps an engine debt row into an app-owned board row, dropping confidence.
    ///
    /// The display name is resolved app-side from the stable `counterpartHandle`
    /// (never the engine's emitted `counterpart`, which the Mac-app engine instance
    /// builds with an empty resolver, so it equals the handle): the injected
    /// `contacts` is the single resolution seam, and an unmatched handle degrades to
    /// the raw handle, never blank.
    internal static func mapRow(
        _ item: StowerDebtItem,
        now: Date,
        contacts: StowerContactsResolver
    ) -> StowerBoardRow {
        let kind = mapKind(item.lastMessageKind)
        let counterpart = contacts.displayName(for: item.counterpartHandle)
        return StowerBoardRow(
            chatID: item.chatID,
            counterpart: counterpart,
            counterpartHandle: item.counterpartHandle,
            draftKey: StowerDraftKey.derive(forHandle: item.counterpartHandle),
            lastMessageGUID: item.lastMessageGUID,
            lastMessageTimestamp: item.lastMessageTimestamp,
            monogram: StowerBoardRow.monogram(for: counterpart),
            summary: StowerLastMessageSummary.make(kind: kind, text: item.lastMessageText),
            ageInDays: StowerBoardRow.ageInDays(from: item.lastMessageTimestamp, to: now),
            deepLink: item.deepLink
        )
    }

    /// Maps engine thread messages into app-owned lines, preserving order (I11).
    ///
    /// The reader produces oldest-first; the order is carried 1:1 (never re-sorted,
    /// which would scramble same-second ties) and the most-recent line is flagged.
    internal static func mapThread(_ messages: [StowerThreadMessage]) -> [StowerThreadLine] {
        let lastIndex = messages.count - 1
        return messages.enumerated().map { index, message in
            StowerThreadLine(
                id: message.id,
                isFromMe: message.isFromMe,
                summary: StowerLastMessageSummary.make(
                    kind: mapKind(message.kind),
                    text: message.text
                ),
                isMostRecent: index == lastIndex
            )
        }
    }

    /// Distills a refresh summary into the app-owned outcome (I6/I6b/I9).
    ///
    /// `nil` is coalesced; a complete pass (`judged + failed == total`) resolves to
    /// rows/caught-up/error via its flags; an incomplete pass is parent-cancelled.
    internal static func mapRefresh(_ summary: StowerRefreshSummary?) -> StowerBoardRefreshOutcome {
        guard let summary else { return .coalesced }
        let reloadNeeded = summary.changedCount > 0
        let isComplete = summary.judgedCount + summary.failedCount == summary.totalCount
        guard isComplete else {
            return .incomplete(reloadNeeded: reloadNeeded)
        }
        return .completed(
            reloadNeeded: reloadNeeded,
            anyJudged: summary.judgedCount > 0,
            hadRecords: summary.totalCount > 0
        )
    }
}
