import Foundation

@testable import StowerMacUI

/// An in-memory `StowerTrialBadgeDismissing` so tests never touch `UserDefaults`.
internal final class StowerInMemoryBadgeDismissal: StowerTrialBadgeDismissing, @unchecked Sendable {
    private let lock = NSLock()
    private var dismissed = false

    internal init() {}

    internal var isDismissed: Bool {
        lock.withLock { dismissed }
    }

    internal func dismiss() {
        lock.withLock { dismissed = true }
    }
}
