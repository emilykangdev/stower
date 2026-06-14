import ArgumentParser
import Foundation
import StowerMessages

/// `stower no-reply` — the local measurement vehicle for the no-reply engine.
///
/// Prints the 1:1 conversations you have not replied to, so you can eyeball
/// whether spam / delivery / 2FA noise slips through before any UI exists.
/// Local-only: it prints real message snippets — do NOT paste its output into
/// logs, issues, prompts, or any AI context.
internal struct NoReplyCommand: AsyncParsableCommand {
    internal static let configuration = CommandConfiguration(
        commandName: "no-reply",
        abstract: """
            List 1:1 conversations you owe a reply to (local-only; do not paste \
            the output anywhere).
            """
    )

    @Option(name: .long, help: "Days of history to read.")
    internal var days: Int = 180

    @Option(name: .customLong("unanswered-days"), help: "Minimum days since their last message.")
    internal var unansweredDays: Int

    @Option(name: .customLong("min-reciprocity"), help: "Minimum recent two-way exchanges.")
    internal var minReciprocity: Int = 1

    internal func run() async throws {
        stowerWarnIfContactsDenied()
        let candidates = try await fetch()
        if candidates.isEmpty {
            print("no-reply: no conversations match.")
            return
        }
        print("no-reply: \(candidates.count) conversation(s) awaiting your reply.")
        for candidate in candidates {
            print(line(for: candidate))
        }
    }

    private func fetch() async throws -> [StowerNoReplyCandidate] {
        do {
            let reader = try StowerChatDatabaseReader()
            return try await reader.noReplyCandidates(
                unansweredForDays: unansweredDays,
                minimumReciprocity: minReciprocity,
                windowDays: days
            )
        } catch let error as StowerMessagesError {
            if case .fullDiskAccessMissing(let path) = error {
                stowerReportFullDiskAccess(path: path)
            } else {
                stowerStandardError(error.localizedDescription)
            }
            throw ExitCode.failure
        }
    }

    private func line(for candidate: StowerNoReplyCandidate) -> String {
        let name = stowerSanitizedForTerminal(candidate.counterpart)
        let age = ageDescription(since: candidate.lastMessageTimestamp)
        return "  \(name) · \(age) · \(snippet(for: candidate))"
    }

    private func snippet(for candidate: StowerNoReplyCandidate) -> String {
        if let text = candidate.lastMessageText {
            return stowerSanitizedForTerminal(String(text.prefix(60)))
        }
        switch candidate.lastMessageKind {
        case .text, .link:
            return "(no preview)"
        case .attachment:
            return "[sent an attachment]"
        case .app:
            return "[sent an app message]"
        case .other:
            return "[sent a message]"
        }
    }

    private func ageDescription(since timestamp: Date) -> String {
        let seconds = Date().timeIntervalSince(timestamp)
        let days = Int(seconds / 86_400)
        if days >= 1 {
            return "\(days)d"
        }
        let hours = Int(seconds / 3_600)
        return "\(hours)h"
    }
}
