import Foundation
import Testing

@testable import StowerMacUI

/// Proves the isolated System Settings opener: both required deep links construct
/// (guard-let, never force-unwrapped), a general-settings fallback exists, and
/// `openPane` routes through the injected opener.
@Suite @MainActor internal struct StowerSystemSettingsOpenerTests {
    @Test("both required pane URLs and the fallback construct")
    internal func paneURLsConstruct() {
        #expect(StowerSystemSettingsOpener.paneURL(for: .fullDiskAccess) != nil)
        #expect(StowerSystemSettingsOpener.paneURL(for: .appleIntelligence) != nil)
        #expect(StowerSystemSettingsOpener.generalSettingsURL != nil)
    }

    @Test("openPane opens the Full Disk Access pane URL")
    internal func opensFullDiskAccessPane() {
        let recorder = StowerOpenedURLRecorder()
        let opener = StowerSystemSettingsOpener(open: { recorder.record($0) })
        opener.openPane(.fullDiskAccess)
        #expect(recorder.opened == StowerSystemSettingsOpener.paneURL(for: .fullDiskAccess))
    }

    @Test("openPane opens the Apple Intelligence pane URL")
    internal func opensAppleIntelligencePane() {
        let recorder = StowerOpenedURLRecorder()
        let opener = StowerSystemSettingsOpener(open: { recorder.record($0) })
        opener.openPane(.appleIntelligence)
        #expect(recorder.opened == StowerSystemSettingsOpener.paneURL(for: .appleIntelligence))
    }
}

/// Records the last URL an opener was asked to open.
///
/// Main-actor isolated, so it is `Sendable` and safe to capture in the opener's
/// `@Sendable @MainActor` closure.
@MainActor private final class StowerOpenedURLRecorder {
    private(set) var opened: URL?

    func record(_ url: URL) {
        opened = url
    }
}
