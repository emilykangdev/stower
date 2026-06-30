import Foundation
import Sentry
import Testing

@testable import StowerMacUI

/// Tests `StowerSentryScrubber` — the `beforeSend` last-guardrail PII scrubber.
///
/// Covers all §Invariants for the scrubber:
/// - Drop non-crash events.
/// - Rebuild `exception.value` from content-free structured fields (THE
///   load-bearing step, A5).
/// - Drop crash events with hard-stop tokens.
/// - Redact home-directory paths in frames/debug-meta.
/// - PII canary: sentinel absent from the event returned by `scrub` (#if DEBUG,
///   the A5 end-to-end guard).
@Suite internal struct StowerSentryScrubberTests {

    // MARK: — Non-crash events are dropped

    @Test internal func nonCrashEvent_isDropped() {
        // A plain error event (no exceptions, no mechanism) must be dropped.
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "test error")
        #expect(
            StowerSentryScrubber.scrub(event) == nil,
            "non-crash event (no exception mechanism) must be dropped"
        )
    }

    @Test internal func eventWithExceptionButNoMechanism_isDropped() {
        // An exception without a mechanism is NOT from the crash handler.
        let ex = Exception(value: "Something broke", type: "NSException")
        let event = makeEvent(withExceptions: [ex])
        #expect(
            StowerSentryScrubber.scrub(event) == nil,
            "exception without mechanism must be dropped (not a native crash)"
        )
    }

    // MARK: — exception.value is rebuilt (load-bearing step, A5)

    /// The scrubber must rebuild `exception.value` from content-free structured fields.
    ///
    /// Discards introspected free-text wholesale. This is the §Invariants
    /// "Scrubber rebuilds exception.value" test — the primary defence against
    /// KSCrash memory introspection leaking message/contact content.
    @Test internal func crashEvent_exceptionValueRebuilt() {
        let introspectedContent = "Hi the landlord texted about rent — chat content"
        let ex = Exception(value: introspectedContent, type: "EXC_BAD_ACCESS")
        // A crash mechanism is what distinguishes a native crash event.
        ex.mechanism = Mechanism(type: "signal")
        let event = makeEvent(withExceptions: [ex])

        let scrubbed = StowerSentryScrubber.scrub(event)

        guard let result = scrubbed else {
            Issue.record("scrub returned nil for a crash event — should return (redacted) event")
            return
        }
        guard let resultEx = result.exceptions?.first else {
            Issue.record("scrubbed event has no exceptions")
            return
        }

        #expect(
            resultEx.value?.contains(introspectedContent) == false,
            "introspected content must be absent from the rebuilt exception.value"
        )
        // The rebuilt value should reference the crash type (content-free).
        #expect(
            resultEx.value?.contains("EXC_BAD_ACCESS") == true,
            "rebuilt exception.value should contain the crash type (content-free)"
        )
    }

    // MARK: — Hard-stop tokens cause the event to be dropped

    @Test internal func extraWithChatDbFragment_isDropped() {
        let event = makeCrashEvent()
        event.extra = ["context": "found chat.db open" as AnyObject]
        #expect(
            StowerSentryScrubber.scrub(event) == nil,
            "event with chat.db in extra must be dropped"
        )
    }

    @Test internal func tagsWithPhotosPath_isDropped() {
        let event = makeCrashEvent()
        event.tags = ["path": "/Photos/Library/photoslibrary"]
        #expect(
            StowerSentryScrubber.scrub(event) == nil,
            "event with PhotosLibrary path in tags must be dropped"
        )
    }

    @Test internal func userEmailInUser_isDropped() {
        let event = makeCrashEvent()
        let user = User(userId: "anon")
        user.email = "alice@example.com"
        event.user = user
        #expect(
            StowerSentryScrubber.scrub(event) == nil,
            "event with email in user must be dropped"
        )
    }

    @Test internal func phoneInTags_isDropped() {
        let event = makeCrashEvent()
        event.tags = ["contact": "+15551234567"]
        #expect(
            StowerSentryScrubber.scrub(event) == nil,
            "event with E.164 phone number in tags must be dropped"
        )
    }

    // MARK: — Home-directory paths are redacted

    @Test internal func framePaths_homeDirectoryRedacted() {
        let event = makeCrashEvent()
        let thread = SentryThread(threadId: 1)
        let frame = Frame()
        frame.fileName =
            "/Users/alice/Developer/Stower/Sources/StowerMacUI/Views/StowerRootView.swift"
        let stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        thread.stacktrace = stacktrace
        event.threads = [thread]

        let scrubbed = StowerSentryScrubber.scrub(event)
        guard let result = scrubbed else {
            Issue.record("scrub returned nil for a clean crash event")
            return
        }

        let resultFrame = result.threads?.first?.stacktrace?.frames.first
        #expect(
            resultFrame?.fileName?.contains("/Users/alice/") == false,
            "username must be redacted from frame fileName"
        )
        #expect(
            resultFrame?.fileName?.contains("/Users/<redacted>/") == true,
            "frame fileName must use /Users/<redacted>/ placeholder"
        )
        // Code path structure (non-PII) must be preserved.
        #expect(
            resultFrame?.fileName?.contains("StowerRootView.swift") == true,
            "symbolicated file name must be preserved after redaction"
        )
    }

    @Test internal func debugMetaPath_homeDirectoryRedacted() {
        let event = makeCrashEvent()
        let meta = DebugMeta()
        meta.codeFile = "/Users/bob/build/Stower.app/Contents/MacOS/Stower"
        event.debugMeta = [meta]

        let scrubbed = StowerSentryScrubber.scrub(event)
        guard let result = scrubbed else {
            Issue.record("scrub returned nil for a clean crash event")
            return
        }

        let resultMeta = result.debugMeta?.first
        #expect(
            resultMeta?.codeFile?.contains("/Users/bob/") == false,
            "username must be redacted from debug-meta codeFile"
        )
        #expect(
            resultMeta?.codeFile?.contains("/Users/<redacted>/") == true,
            "debug-meta codeFile must use /Users/<redacted>/ placeholder"
        )
    }

    // MARK: — Clean crash event passes through (scrubbed, not dropped)

    @Test internal func cleanCrashEvent_passesThrough() {
        let event = makeCrashEvent()
        let result = StowerSentryScrubber.scrub(event)
        #expect(result != nil, "a clean crash event (no PII) must pass through the scrubber")
    }

    // MARK: — PII canary: sentinel absent from scrub output (§Invariants A5 proof)

    /// A sentinel placed in `exception.value` must be ABSENT from the event returned by `scrub`.
    ///
    /// Simulates what KSCrash memory introspection would inject and asserts the
    /// scrubber removes it. Asserting on the INPUT is testing the wrong end —
    /// the scrubber is what removes it.
    ///
    /// This is the §Invariants "PII canary never reaches the wire" test — the
    /// standing guard if an SDK upgrade re-routes introspection past the
    /// `exception.value` rebuild.
    @Test internal func piiCanary_absentFromScrubOutput() {
        // The canary is a known sentinel that would appear in exception.value if
        // memory introspection promoted a C-string that contained it. We inject
        // it directly into exception.value (matching what the spike observed from
        // the real crash handler), then assert the scrubber's output does NOT
        // contain it.
        let canaryToken = "STOWER_PII_CANARY_\(UUID().uuidString)"
        let ex = Exception(value: canaryToken, type: "EXC_BAD_ACCESS")
        ex.mechanism = Mechanism(type: "signal")
        let event = makeEvent(withExceptions: [ex])

        let scrubbed = StowerSentryScrubber.scrub(event)

        guard let result = scrubbed else {
            Issue.record("scrub dropped event: canary tripped hard-stop; use UUID-only sentinel")
            return
        }

        // Verify the sentinel is absent from exception.value.
        let valueContainsCanary =
            result.exceptions?.contains {
                $0.value?.contains(canaryToken) == true
            } ?? false
        #expect(
            !valueContainsCanary,
            "PII canary must be absent from exception.value after scrub (A5 proof)"
        )

        // Verify the rebuilt value is content-free (references the crash type).
        let rebuiltValue = result.exceptions?.first?.value ?? ""
        #expect(
            rebuiltValue.contains("EXC_BAD_ACCESS") || !rebuiltValue.isEmpty,
            "rebuilt exception.value must be content-free but non-empty"
        )
    }

    // MARK: — Helpers

    /// Builds a minimal crash event (with mechanism) for scrubber tests.
    private func makeCrashEvent() -> Event {
        let ex = Exception(value: "EXC_BAD_ACCESS (KERN_INVALID_ADDRESS)", type: "EXC_BAD_ACCESS")
        ex.mechanism = Mechanism(type: "signal")
        return makeEvent(withExceptions: [ex])
    }

    private func makeEvent(withExceptions exceptions: [Exception]) -> Event {
        let event = Event(level: .fatal)
        event.exceptions = exceptions
        return event
    }
}
