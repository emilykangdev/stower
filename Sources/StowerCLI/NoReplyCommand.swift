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

    @Option(
        name: .customLong("unanswered-days"),
        help: "Minimum days since their last message (must be <= --days)."
    )
    internal var unansweredDays: Int

    @Option(name: .customLong("min-reciprocity"), help: "Minimum recent two-way exchanges.")
    internal var minReciprocity: Int = 1

    internal func run() async throws {
        guard unansweredDays <= days else {
            stowerStandardError(
                "--unanswered-days (\(unansweredDays)) must not exceed --days (\(days))."
            )
            throw ExitCode.failure
        }
        stowerWarnIfContactsDenied()
        let items = try await fetch()
        if items.isEmpty {
            print("no-reply: no conversations match.")
            return
        }
        print("no-reply: \(items.count) conversation(s) awaiting your reply.")
        for item in items {
            print(line(for: item))
        }
    }

    private func fetch() async throws -> [StowerDebtItem] {
        do {
            // The CLI is a structural + heuristic measurement vehicle: no cache,
            // no on-device model, deterministic output.
            let provider = StowerDebtBoardProvider(cacheURL: nil, windowDays: days)
            let config = StowerDebtConfig(
                unansweredForDays: unansweredDays,
                minimumReciprocity: minReciprocity,
                judgeMode: .heuristic
            )
            return try await provider.loadDebtBoard(config: config, now: Date()).neglected
        } catch let error as StowerMessagesError {
            if case .fullDiskAccessMissing(let path) = error {
                stowerReportFullDiskAccess(path: path)
            } else {
                stowerStandardError(error.localizedDescription)
            }
            throw ExitCode.failure
        }
    }

    private func line(for item: StowerDebtItem) -> String {
        let name = stowerSanitizedForTerminal(item.counterpart)
        let age = ageDescription(since: item.lastMessageTimestamp)
        return "  \(name) · \(age) · \(snippet(for: item))"
    }

    private func snippet(for item: StowerDebtItem) -> String {
        if let text = item.lastMessageText {
            return stowerSanitizedForTerminal(String(text.prefix(60)))
        }
        switch item.lastMessageKind {
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
