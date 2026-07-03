import Foundation
import Testing

@testable import StowerMacUI

/// The pure `effectiveSourceURL(environment:allowOverrides:)` layer: `STOWER_MESSAGES_DB`
/// redirects the board's source only when overrides are allowed (DEBUG), and an
/// absent/blank value or a disallowed (Release) build falls back to `nil` — proven
/// without mutating `ProcessInfo`.
@Suite internal struct StowerMessagesSourceOverrideTests {
    private static let key = "STOWER_MESSAGES_DB"

    @Test("a set path resolves to that file URL when overrides are allowed")
    internal func setPathResolvesWhenAllowed() {
        let url = StowerMessagesSourceOverride.effectiveSourceURL(
            environment: [Self.key: "/tmp/demo/chat.db"],
            allowOverrides: true
        )
        #expect(url == URL(fileURLWithPath: "/tmp/demo/chat.db"))
    }

    @Test("a leading tilde is expanded to the home directory")
    internal func tildeIsExpanded() {
        let url = StowerMessagesSourceOverride.effectiveSourceURL(
            environment: [Self.key: "~/demo/chat.db"],
            allowOverrides: true
        )
        let expanded = ("~/demo/chat.db" as NSString).expandingTildeInPath
        #expect(url == URL(fileURLWithPath: expanded))
        #expect(url?.path.contains("~") == false)
    }

    @Test("overrides disallowed (Release) always yields nil, even with the key set")
    internal func disallowedYieldsNil() {
        let url = StowerMessagesSourceOverride.effectiveSourceURL(
            environment: [Self.key: "/tmp/demo/chat.db"],
            allowOverrides: false
        )
        #expect(url == nil)
    }

    @Test("an unset key yields nil")
    internal func unsetKeyYieldsNil() {
        let url = StowerMessagesSourceOverride.effectiveSourceURL(
            environment: [:],
            allowOverrides: true
        )
        #expect(url == nil)
    }

    @Test("a blank or whitespace-only value falls back to nil")
    internal func blankValueYieldsNil() {
        let empty = StowerMessagesSourceOverride.effectiveSourceURL(
            environment: [Self.key: ""],
            allowOverrides: true
        )
        let whitespace = StowerMessagesSourceOverride.effectiveSourceURL(
            environment: [Self.key: "   \n"],
            allowOverrides: true
        )
        #expect(empty == nil)
        #expect(whitespace == nil)
    }
}
