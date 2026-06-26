import CryptoKit
import Foundation
import IOKit

/// Produces the device fingerprint sent to the trial-mint server: the SHA-256
/// hex of a stable per-machine UUID.
///
/// The UUID is the IOKit `IOPlatformUUID` — readable with no entitlement and
/// stable across an OS reinstall (Apple TN1103). When IOKit returns none, a UUID
/// generated once and cached in the Keychain stands in, so the fingerprint is
/// still stable for that device.
///
/// The raw UUID is hashed before it ever leaves the device; only the hash is
/// sent to the mint server (the dedupe key). The `IOPlatformUUID` read is a
/// blocking synchronous IOKit call, so `fingerprint()` is `nonisolated` and the
/// type holds no actor-isolated state — callers run it off the main actor.
internal struct StowerDeviceFingerprint: Sendable {
    /// Reads the hardware UUID, or `nil` when IOKit exposes none.
    internal typealias HardwareUUIDReader = @Sendable () -> String?

    /// Reads (creating once) the cached fallback UUID — Keychain in production.
    internal typealias FallbackUUIDProvider = @Sendable () -> String

    private let readHardwareUUID: HardwareUUIDReader
    private let fallbackUUID: FallbackUUIDProvider

    /// Creates a fingerprint source.
    ///
    /// - Parameters:
    ///   - readHardwareUUID: Reads `IOPlatformUUID`; injected so tests need no
    ///     IOKit. Defaults to the real registry read.
    ///   - fallbackUUID: Supplies a stable UUID when IOKit returns none; injected
    ///     so tests need no Keychain. Defaults to the Keychain-cached generator.
    internal init(
        readHardwareUUID: @escaping HardwareUUIDReader = StowerDeviceFingerprint.platformUUID,
        fallbackUUID: @escaping FallbackUUIDProvider = StowerDeviceFingerprint.keychainFallbackUUID
    ) {
        self.readHardwareUUID = readHardwareUUID
        self.fallbackUUID = fallbackUUID
    }

    /// Returns the SHA-256 hex of the device UUID.
    ///
    /// Never returns the raw UUID.
    internal func fingerprint() -> String {
        let uuid = readHardwareUUID() ?? fallbackUUID()
        return Self.sha256Hex(uuid)
    }

    /// SHA-256 of a string's UTF-8 bytes, as lowercase hex.
    internal static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `IOPlatformUUID` from the IOKit registry's platform-expert device,
    /// or `nil` when the property is absent.
    internal static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(platformExpertDeviceClass)
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service,
            platformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return property?.takeRetainedValue() as? String
    }

    /// A UUID generated once and cached in the Keychain, used when IOKit exposes
    /// no `IOPlatformUUID`.
    ///
    /// A read miss generates and stores a fresh UUID; if the Keychain write fails
    /// the generated UUID is still returned (stable for the session, not across
    /// launches — the documented degraded case).
    internal static func keychainFallbackUUID() -> String {
        let item = StowerKeychainItem(
            service: fallbackKeychainService,
            account: fallbackKeychainAccount
        )
        if let data = item.readData(), let existing = String(data: data, encoding: .utf8) {
            return existing
        }
        let generated = UUID().uuidString
        _ = item.write(Data(generated.utf8))
        return generated
    }

    private static let platformExpertDeviceClass = "IOPlatformExpertDevice"
    private static let platformUUIDKey = "IOPlatformUUID"
    private static let fallbackKeychainService = "com.stower.license.fingerprint"
    private static let fallbackKeychainAccount = "fallback-uuid"
}
