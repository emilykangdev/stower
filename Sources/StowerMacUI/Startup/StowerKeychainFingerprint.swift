import CryptoKit
import Foundation
import os

/// Produces the install fingerprint sent to the licensing server: the SHA-256
/// hex of a random, app-scoped UUID kept in the login Keychain.
///
/// The UUID is generated once on first run and stored under service
/// `"com.stower.license.fingerprint"` / account `"install-uuid"`. It is
/// app-scoped, random, and user-resettable — it never identifies the machine and
/// never correlates across apps (master-brief D1). Because the StowerMac app is
/// not sandboxed, the login-Keychain item survives a drag-to-trash reinstall
/// (D2), so a naive reinstall reuses the same identity.
///
/// The raw UUID is hashed before it ever leaves the device; only the hash is
/// sent to the licensing server (the dedupe key). The Keychain read is a
/// blocking synchronous syscall, so `fingerprint()` is `nonisolated` and the
/// type holds no actor-isolated state — callers run it off the main actor.
///
/// The resolved UUID is memoized once per instance. A Keychain whose write keeps
/// failing would otherwise hand back a freshly generated UUID on every call, so
/// the app would mint under one fingerprint and then reject its own returned
/// machine file under another. The memo keeps the identity stable for the whole
/// process even on write failure — it is NOT persisted across launches until a
/// write succeeds.
internal struct StowerKeychainFingerprint: Sendable {
    /// Reads (creating once) the random install UUID — Keychain in production.
    internal typealias InstallUUIDProvider = @Sendable () -> String

    private let installUUID: InstallUUIDProvider

    /// Memoizes the resolved UUID once per instance.
    ///
    /// Guarded by a lock so concurrent `fingerprint()` callers resolve a single
    /// value. Holds `nil` until the first `fingerprint()` resolves it — never
    /// resolved eagerly in `init`, to keep the blocking Keychain read off the
    /// (possibly main-actor) construction.
    private let resolvedUUID = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Creates a fingerprint source.
    ///
    /// - Parameter installUUID: Supplies the random install UUID; injected so
    ///   tests need no Keychain. Defaults to the Keychain-backed generator.
    internal init(
        installUUID: @escaping InstallUUIDProvider = StowerKeychainFingerprint.keychainInstallUUID
    ) {
        self.installUUID = installUUID
    }

    /// Returns the SHA-256 hex of the install UUID.
    ///
    /// Resolves the UUID exactly once per instance — lazily, off the main actor —
    /// and reuses it thereafter, so every consumer in a process sees the same
    /// identity. Never returns the raw UUID.
    internal func fingerprint() -> String {
        let uuid = resolvedUUID.withLock { box -> String in
            if let existing = box { return existing }
            let value = installUUID()
            box = value
            return value
        }
        return Self.sha256Hex(uuid)
    }

    /// SHA-256 of a string's UTF-8 bytes, as lowercase hex.
    internal static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A random UUID generated once and cached in the login Keychain.
    ///
    /// A read miss — or a stored value that is not a well-formed UUID — generates
    /// and stores a fresh UUID; if the Keychain write fails the generated UUID is
    /// still returned (stable for the process via the instance memo, not across
    /// launches — the documented degraded case). The UUID-shape check keeps a
    /// corrupt/empty stored value from collapsing identity onto `sha256("")`.
    internal static func keychainInstallUUID() -> String {
        let item = StowerKeychainItem(
            service: installKeychainService,
            account: installKeychainAccount
        )
        let stored = item.readData().flatMap { String(data: $0, encoding: .utf8) }
        if let existing = stored, UUID(uuidString: existing) != nil {
            return existing
        }
        let generated = UUID().uuidString
        _ = item.write(Data(generated.utf8))
        return generated
    }

    private static let installKeychainService = "com.stower.license.fingerprint"
    private static let installKeychainAccount = "install-uuid"
}
