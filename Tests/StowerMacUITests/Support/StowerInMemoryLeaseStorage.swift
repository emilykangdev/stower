import Foundation

@testable import StowerMacUI

/// An in-memory `StowerLeaseStorage` so the lease/gate tests touch neither the
/// Keychain nor disk.
internal final class StowerInMemoryLeaseStorage: StowerLeaseStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?

    internal init() {}

    internal func readData() -> Data? {
        lock.withLock { blob }
    }

    @discardableResult
    internal func write(_ data: Data) -> Bool {
        lock.withLock { blob = data }
        return true
    }

    internal func delete() {
        lock.withLock { blob = nil }
    }
}
