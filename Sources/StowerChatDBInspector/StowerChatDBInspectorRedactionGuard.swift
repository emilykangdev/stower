import Foundation

/// The fail-closed redaction guard for the inspector's report.
///
/// Ported verbatim (same two patterns, same fail-closed semantics) from
/// `Scripts/inspect-chatdb-shapes.sh`'s `report_has_content`/`GUARD_PATTERN`/
/// `GUARD_LONGTOKEN` (JC6) — this Swift executable is that script's
/// compiled, sandboxed replacement, not a redesign of its safety guarantees.
internal enum StowerChatDBInspectorRedactionGuard {
    /// An email address, an E.164-shaped phone number, or a hyphenated hex
    /// UUID (a message GUID's shape) — unambiguously real content wherever
    /// it appears.
    private static let contentPattern = makeRegularExpression(
        pattern: #"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})|"#
            + #"(\+[0-9 ()-]{6,})|"#
            + #"([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#
    )

    /// A long opaque run (>=25 of `[A-Za-z0-9_-]`) — treated as content only
    /// when it also contains a digit (catches base64/hex blobs and bare
    /// GUIDs while not flagging readable all-letter identifier words, e.g. an
    /// Apple bundle-id segment).
    private static let longTokenPattern = makeRegularExpression(pattern: "[A-Za-z0-9_-]{25,}")

    /// Compiles a known-valid, compile-time-constant regex pattern.
    ///
    /// Never `try!`/force-unwrapped (AGENTS.md): a compile failure here is a
    /// programmer error in the two hardcoded patterns above, so it fails via
    /// `preconditionFailure` with an explicit message instead.
    private static func makeRegularExpression(pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("StowerChatDBInspectorRedactionGuard pattern failed to compile")
        }
        return regex
    }

    /// Returns whether `text` contains something content-shaped.
    ///
    /// Callers treat `true` as fail-closed: abort, print nothing.
    internal static func reportHasContent(_ text: String) -> Bool {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if contentPattern.firstMatch(in: text, range: fullRange) != nil {
            return true
        }
        return longTokens(in: text).contains { $0.contains(where: \.isNumber) }
    }

    /// Every substring matching `longTokenPattern`.
    ///
    /// Kept private to this file; the report path only needs
    /// `reportHasContent`'s boolean.
    private static func longTokens(in text: String) -> [String] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return longTokenPattern.matches(in: text, range: fullRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// Proves the guard catches content and passes structural output, using
    /// only synthetic, fabricated strings (no `chat.db`, no real data).
    ///
    /// Mirrors the bash script's `--self-test` exactly: four positives that
    /// must trip the guard (phone, email, hex UUID, a long opaque run with a
    /// digit) and two negatives that must pass (a clean structural line and a
    /// long all-letter identifier word).
    internal static func runSelfTest() -> Bool {
        let positivesPassed = checkPositivesTripTheGuard()
        let negativesPassed = checkNegativesPassCleanly()
        let headersPassed = checkAllSectionHeadersPresent()
        let allPassed = positivesPassed && negativesPassed && headersPassed

        if allPassed {
            print("self-test passed: redaction guard works and all five sections are defined")
        } else {
            FileHandle.standardError.write(Data("self-test FAILED\n".utf8))
        }
        return allPassed
    }

    /// Four positives that must trip the guard: phone, email, hex UUID, and a
    /// long opaque run that carries a digit.
    private static func checkPositivesTripTheGuard() -> Bool {
        let positives = [
            "+14155550100",
            "tester@example.com",
            "4F2AE8B0-1234-5678-9ABC-DEF012345678",
            "AB12CD34EF56GH78IJ90KL12MN34"
        ]
        var allPassed = true
        for value in positives {
            if reportHasContent(value) {
                print("ok: guard caught a synthetic content-shaped value")
            } else {
                FileHandle.standardError.write(
                    Data("FAIL: guard MISSED a synthetic content value\n".utf8)
                )
                allPassed = false
            }
        }
        return allPassed
    }

    /// Two negatives that must PASS: a clean structural line, and a long
    /// all-letter identifier word (an Apple bundle-id segment is not content).
    private static func checkNegativesPassCleanly() -> Bool {
        let negatives = [
            "com.apple.messages.URLBalloonProvider = 128   p:<redacted> = 40   "
                + "type 2000 (added) = 12",
            "  com.apple.messages.MSMessageExtensionBalloonPlugin = 73"
        ]
        var allPassed = true
        for value in negatives {
            if reportHasContent(value) {
                FileHandle.standardError.write(
                    Data("FAIL: guard false-positived on clean structural output\n".utf8)
                )
                allPassed = false
            } else {
                print("ok: guard passed a clean structural line")
            }
        }
        return allPassed
    }

    /// I5: the five section headers (esp. 1 and 4) must all be non-empty.
    private static func checkAllSectionHeadersPresent() -> Bool {
        var allPassed = true
        for header in StowerChatDBInspectorSections.all.map(\.header) where header.isEmpty {
            FileHandle.standardError.write(Data("FAIL: a section header is empty\n".utf8))
            allPassed = false
        }
        return allPassed
    }
}
