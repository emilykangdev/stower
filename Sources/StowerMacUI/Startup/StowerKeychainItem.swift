import Foundation
import Security

/// A generic-blob persistence seam: read/write/delete of one opaque blob.
///
/// Production is `StowerKeychainItem`; tests inject an in-memory fake so they
/// touch neither the Keychain nor disk. Extracted from the deleted Keygen
/// lease store — this is now the production storage for Diagnostics
/// (`StowerDiagnosticsConsent`, `StowerDiagnosticsIdentity`), not licensing.
internal protocol StowerLeaseStorage: Sendable {
    /// Reads the stored blob, or `nil` when absent.
    func readData() -> Data?

    /// Replaces the stored blob; returns whether the write succeeded.
    @discardableResult
    func write(_ data: Data) -> Bool

    /// Removes the stored blob.
    func delete()
}

/// A typed read/write/delete over a single Keychain generic-password item.
///
/// Stored with `kSecAttrAccessibleAfterFirstUnlock` (device-only, available
/// after the first unlock, survives reboot) and `kSecAttrSynchronizable: false`
/// (never synced to iCloud) — a device-bound record must not roam.
internal struct StowerKeychainItem: StowerLeaseStorage {
    private let service: String
    private let account: String

    /// Creates an accessor for the `service`/`account` item pair.
    internal init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// The class/service/account triple identifying this item.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    internal func readData() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return nil
        }
        return data
    }

    @discardableResult
    internal func write(_ data: Data) -> Bool {
        // Update the existing item in place; add only when none exists. A plain
        // delete-then-add would destroy a valid stored record if the add then failed
        // (a transient Keychain error), losing it. delete() stays reserved for an
        // explicit clear().
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    internal func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
