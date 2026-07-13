import Foundation
import Testing

@testable import StowerMacUI

/// Proves the isolated System Settings opener: both required deep links construct
/// (guard-let, never force-unwrapped), and `openPane` opens the pane URL — falling
/// back to general System Settings when the pane URL fails to open, so the user is
/// never stranded.
@Suite @MainActor internal struct StowerSystemSettingsOpenerTests {
    @Test("both required pane URLs and the fallback construct")
    internal func paneURLsConstruct() {
        #expect(StowerSystemSettingsOpener.paneURL(for: .appleIntelligence) != nil)
        #expect(StowerSystemSettingsOpener.paneURL(for: .contacts) != nil)
        #expect(StowerSystemSettingsOpener.generalSettingsURL != nil)
    }

    @Test("openPane opens the Contacts pane URL and does not fall back")
    internal func opensContactsPane() {
        let recorder = StowerOpenedURLRecorder()
        let opener = StowerSystemSettingsOpener(open: { recorder.record($0) })
        opener.openPane(.contacts)
        #expect(recorder.opened.count == 1)
        #expect(recorder.opened.first == StowerSystemSettingsOpener.paneURL(for: .contacts))
    }

    @Test("openPane opens the Apple Intelligence pane URL and does not fall back")
    internal func opensAppleIntelligencePane() {
        let recorder = StowerOpenedURLRecorder()
        let opener = StowerSystemSettingsOpener(open: { recorder.record($0) })
        opener.openPane(.appleIntelligence)
        #expect(recorder.opened.count == 1)
        #expect(
            recorder.opened.first == StowerSystemSettingsOpener.paneURL(for: .appleIntelligence)
        )
    }

    @Test("a pane URL that fails to open falls back to general System Settings")
    internal func fallsBackWhenPaneFailsToOpen() {
        let recorder = StowerOpenedURLRecorder()
        recorder.result = false  // every open "fails", forcing the fallback attempt
        let opener = StowerSystemSettingsOpener(open: { recorder.record($0) })
        opener.openPane(.appleIntelligence)
        #expect(recorder.opened.count == 2)
        #expect(
            recorder.opened.first == StowerSystemSettingsOpener.paneURL(for: .appleIntelligence)
        )
        #expect(recorder.opened.last == StowerSystemSettingsOpener.generalSettingsURL)
    }
}

/// Records every URL an opener was asked to open and returns a scriptable result.
///
/// Main-actor isolated, so it is `Sendable` and safe to capture in the opener's
/// `@Sendable @MainActor` closure.
@MainActor private final class StowerOpenedURLRecorder {
    private(set) var opened: [URL] = []
    var result = true

    func record(_ url: URL) -> Bool {
        opened.append(url)
        return result
    }
}
