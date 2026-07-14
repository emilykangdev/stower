import Foundation
import StowerMacUI
import StowerMessages

/// `stower-chatdb-inspector` — read-only, redacted `chat.db` shape diagnostic.
///
/// The compiled, sandbox-compatible replacement for the deleted
/// `Scripts/inspect-chatdb-shapes.sh` (JC6): a bash script cannot host an App
/// Sandbox (no bundle, no entitlements, no code-signature identity beyond
/// ad-hoc), so the only way to give this dev-only diagnostic the Powerbox
/// bypass is a compiled, signed executable. Presents its own ephemeral
/// `NSOpenPanel` picker every run via the SHARED `StowerMessagesAccessPicker`
/// (JC7) — same JC1 shape as `StowerCLI`: never persists a bookmark.
///
/// Answers the same two empirical questions the bash script did: how a
/// reaction's target GUID is prefix-encoded, and how a Maps/URL link lands —
/// against the REAL `chat.db`, emitting only structural aggregates (no
/// message body, handle, chat identifier, or full GUID value).

internal let arguments = Array(CommandLine.arguments.dropFirst())

switch StowerChatDBInspectorMode(arguments: arguments) {
case .help:
    print(StowerChatDBInspectorUsage.text)
case .unknown(let argument):
    StowerChatDBInspectorRunner.reportUnknownArgument(argument)
    exit(1)
case .selfTest:
    exit(StowerChatDBInspectorRedactionGuard.runSelfTest() ? 0 : 1)
case .report:
    do {
        try StowerChatDBInspectorRunner.run()
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

/// The one argument this executable understands, parsed once at launch.
internal enum StowerChatDBInspectorMode {
    case report
    case selfTest
    case help
    case unknown(String)

    internal init(arguments: [String]) {
        switch arguments.first {
        case .none:
            self = .report
        case "--self-test":
            self = .selfTest
        case "--help", "-h":
            self = .help
        case .some(let other):
            self = .unknown(other)
        }
    }
}

internal enum StowerChatDBInspectorUsage {
    internal static let text = """
        stower-chatdb-inspector — read-only, redacted chat.db shape diagnostic.

        Usage:
          stower-chatdb-inspector            # run the report (presents a picker)
          stower-chatdb-inspector --self-test  # prove the guard works, no real data
          stower-chatdb-inspector --help
        """
}
