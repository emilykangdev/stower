// ONE of exactly two files in Stower that import Sentry (precheck 6l).
import Sentry

/// Last-guardrail `beforeSend` scrubber for crash events.
///
/// Four jobs, applied in order:
/// 1. **Drop non-crash events** — the crash integration allowlist
///    (`removeAllIntegrations` + `enableCrashHandler`) prevents non-crash
///    integrations from installing; this is the defence-in-depth backstop for
///    anything that slips through or a future SDK default adds.
/// 2. **Rebuild `exceptions[].value`** (THE load-bearing step — spike A5,
///    verified 2026-06-29): KSCrash memory introspection promotes notable-address
///    strings (including message/contact text in C/CFString buffers) INTO
///    `exception.value` wholesale. The scrubber replaces that field with a
///    content-free string built from `ex.type` and the signal/mach context —
///    a deterministic field-replace, NOT content-detection, so it cannot miss.
/// 3. **Redact home-directory paths** in frame `fileName` and debug-meta
///    `codeFile` fields: `/Users/<name>/` → `/Users/<redacted>/`.
/// 4. **Backstop-drop** the whole event if a hard-stop token survives in any
///    string field (chat.db path, Photos path, message/contact-looking text,
///    license-ID shape, device-fingerprint, email, phone). Dropping is safer
///    than partial redaction for tokens we cannot deterministically scrub.
///
/// `scrub` is a pure function (no side effects, no main-actor hops) as required
/// for `beforeSend` which runs on the SDK's background thread (Gotcha 5).
internal enum StowerSentryScrubber {

    // MARK: — PII patterns (named constants; AGENTS: no magic literals)

    /// Matches `/Users/<anything>/` — the macOS home-directory prefix that
    /// carries the system username.
    private static let homePathPattern = try? NSRegularExpression(
        pattern: #"/Users/[^/]+/"#,
        options: []
    )

    /// Hard-stop tokens whose presence means the whole event should be dropped.
    ///
    /// Each string is a lower-case fragment; matching is case-insensitive.
    /// `chat.db` and Photos paths indicate database/library content leaked into
    /// the crash payload. Email/phone shapes indicate contact PII. License-ID
    /// and fingerprint shapes indicate identifiers that should never appear in
    /// crash strings (first-party code is guarded by precheck 6n; these catch
    /// dependency-originated content).
    private static let hardStopFragments: [String] = [
        "chat.db",
        "/photos/",
        "photoslibrary",
        "mediaanalysis",
        "license_key=",
        "lmnt_",
        "device_fingerprint"
    ]

    /// Hard-stop regex patterns (email, phone E.164 shape).
    private static let hardStopPatterns: [NSRegularExpression] = {
        let sources = [
            // Simple email shape (not an exhaustive validator — just enough to
            // catch an accidental email in a crash string).
            #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#,
            // E.164-style phone: +countrycode followed by 7–14 digits.
            #"\+[1-9]\d{6,14}"#
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // MARK: — Public entry point

    /// Scrubs a Sentry crash event before it is transmitted.
    ///
    /// Returns `nil` (drop) for non-crash events and for crash events that
    /// contain hard-stop tokens that cannot be confidently redacted.
    ///
    /// Returns the mutated event for crash events whose PII has been scrubbed.
    /// The `exceptions[].value` field is always rebuilt from content-free
    /// structured fields — never passed through as-is (A5, spike-verified).
    ///
    /// Pure and side-effect-free (safe to call on any thread, A5/Gotcha 5).
    internal static func scrub(_ event: Event) -> Event? {
        // Step 0: drop anything that is not a native crash (defence-in-depth).
        guard isCrashEvent(event) else { return nil }

        // Step 1: rebuild exception.value from content-free structured fields,
        // discarding the introspected free-text wholesale. This is THE load-bearing
        // step — the spike proved KSCrash promotes notable-address strings into
        // this field; a deterministic field-replace cannot miss.
        if let exceptions = event.exceptions {
            for ex in exceptions {
                ex.value = safeReason(for: ex)
            }
        }

        // Step 2: redact home-directory paths in per-frame fileName fields.
        redactFramePaths(in: event)

        // Step 3: redact home-directory paths in debug-meta codeFile fields.
        redactDebugMetaPaths(in: event)

        // Step 4: backstop-drop if a hard-stop token survives in any string field.
        guard !containsHardStopToken(event) else { return nil }

        return event
    }

    // MARK: — Step 0: is this a crash event?

    /// Returns `true` when the event has a crash mechanism in its exceptions.
    ///
    /// A native crash written by `SentryCrashIntegration` always carries at
    /// least one `Exception` whose `mechanism.type` is one of the known
    /// crash mechanism strings. The `level` is additionally `.fatal` for
    /// crashes, but the mechanism check is the stricter filter.
    private static func isCrashEvent(_ event: Event) -> Bool {
        guard let exceptions = event.exceptions, !exceptions.isEmpty else { return false }
        // Any exception with a non-nil mechanism is sufficient — the crash
        // integration always populates mechanism for native crashes.
        return exceptions.contains { $0.mechanism != nil }
    }

    // MARK: — Step 1: content-free crash reason

    /// Builds a content-free crash-reason string from structured fields only.
    ///
    /// Uses `ex.type` (the signal/exception class name, e.g. `EXC_BAD_ACCESS`)
    /// and the mach-exception or signal context from `mechanism.meta` if
    /// available. Never touches the original `ex.value` (which may carry
    /// introspected notable-address strings — see A5).
    private static func safeReason(for ex: Exception) -> String {
        let typePart = ex.type ?? "Unknown"

        // Pull structured signal/mach info from mechanism meta if present.
        if let meta = ex.mechanism?.meta {
            if let signal = meta.signal, let sigName = signal["name"] as? String {
                return "\(typePart) (\(sigName))"
            }
            if let mach = meta.machException, let exName = mach["exception_name"] as? String {
                return "\(typePart) (\(exName))"
            }
        }

        return typePart
    }

    // MARK: — Step 2 & 3: path redaction helpers

    /// Redacts `/Users/<name>/` in every frame's `fileName` field.
    private static func redactFramePaths(in event: Event) {
        guard let threads = event.threads else { return }
        for thread in threads {
            guard let stacktrace = thread.stacktrace else { continue }
            for frame in stacktrace.frames {
                frame.fileName = frame.fileName.map { redactHomePath(in: $0) }
            }
        }
        // Also walk exception stacktraces.
        guard let exceptions = event.exceptions else { return }
        for ex in exceptions {
            guard let stacktrace = ex.stacktrace else { continue }
            for frame in stacktrace.frames {
                frame.fileName = frame.fileName.map { redactHomePath(in: $0) }
            }
        }
    }

    /// Redacts `/Users/<name>/` in every `SentryDebugMeta.codeFile` field.
    private static func redactDebugMetaPaths(in event: Event) {
        guard let debugMeta = event.debugMeta else { return }
        for meta in debugMeta {
            meta.codeFile = meta.codeFile.map { redactHomePath(in: $0) }
        }
    }

    /// Replaces the home-directory prefix `/Users/<name>/` with `/Users/<redacted>/` in `string`.
    ///
    /// Returns the original if no match.
    private static func redactHomePath(in string: String) -> String {
        guard let regex = homePathPattern else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(
            in: string,
            options: [],
            range: range,
            withTemplate: "/Users/<redacted>/"
        )
    }

    // MARK: — Step 4: backstop hard-stop scan

    /// Returns `true` if any string field in the event contains a hard-stop token.
    ///
    /// Scans: `event.extra`, `event.tags`, `event.context`, `event.user`
    /// string fields, and mechanism desc. The `exception.value` fields have
    /// already been rebuilt in step 1 (content-free), so this backstop catches
    /// anything that slipped through other fields.
    private static func containsHardStopToken(_ event: Event) -> Bool {
        let strings = gatherScanStrings(from: event)
        return strings.contains { isHardStop($0) }
    }

    /// Collects all user-controlled string fields from an event for hard-stop scanning.
    private static func gatherScanStrings(from event: Event) -> [String] {
        var strings: [String] = []
        strings += extraStrings(from: event.extra)
        strings += tagStrings(from: event.tags)
        if let context = event.context { strings += flattenContext(context) }
        strings += userStrings(from: event.user)
        // Mechanism desc only — exception.value was rebuilt from ex.type in step 1.
        if let exceptions = event.exceptions {
            strings += exceptions.compactMap { $0.mechanism?.desc }
        }
        return strings
    }

    private static func extraStrings(from extra: [String: Any]?) -> [String] {
        guard let extra else { return [] }
        var result: [String] = []
        for (key, value) in extra {
            result.append(key)
            if let str = value as? String { result.append(str) }
        }
        return result
    }

    private static func tagStrings(from tags: [String: String]?) -> [String] {
        guard let tags else { return [] }
        return tags.flatMap { [$0.key, $0.value] }
    }

    private static func userStrings(from user: User?) -> [String] {
        guard let user else { return [] }
        return [user.email, user.username, user.name, user.userId].compactMap { $0 }
    }

    /// Returns `true` when `string` contains any hard-stop fragment or pattern.
    private static func isHardStop(_ string: String) -> Bool {
        let lower = string.lowercased()
        if hardStopFragments.contains(where: { lower.contains($0) }) { return true }
        let range = NSRange(string.startIndex..., in: string)
        return hardStopPatterns.contains {
            $0.firstMatch(in: string, options: [], range: range) != nil
        }
    }

    /// Flattens a context dictionary (nested dicts of string-keyed values) into
    /// a flat array of strings for hard-stop scanning.
    private static func flattenContext(
        _ context: [String: [String: Any]]
    ) -> [String] {
        var result: [String] = []
        for (outerKey, inner) in context {
            result.append(outerKey)
            for (innerKey, value) in inner {
                result.append(innerKey)
                if let str = value as? String { result.append(str) }
            }
        }
        return result
    }
}
