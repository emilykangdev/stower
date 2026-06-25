import CryptoKit
import Foundation
import Security

/// A cached license lease: the Keygen license key the app authenticates with,
/// the license resource id (the join key a purchase upgrades), the signed
/// machine-file checked out for offline validation, and when it was last
/// validated online.
///
/// `licenseID` is the Keygen resource id (a UUID), never the secret `licenseKey`;
/// the paywall needs it to build the upgrade checkout URL.
internal struct StowerLicenseLease: Sendable, Equatable, Codable {
    /// The Keygen license key (the secret credential the app authenticates with).
    internal let licenseKey: String

    /// The Keygen license resource id (UUID) — the purchase/upgrade join key.
    internal let licenseID: String

    /// The PEM-enveloped, Ed25519-signed machine-file from a Keygen check-out.
    internal let machineFile: String

    /// When the lease was last validated online (the grace window's anchor).
    internal let validatedAt: Date
}

/// The lease store's persistence seam: read/write/delete of one opaque blob.
///
/// Production is `StowerKeychainItem`; tests inject an in-memory fake so they
/// touch neither the Keychain nor disk.
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
/// (never synced to iCloud) — a device-bound lease must not roam.
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
        delete()
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    internal func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Persists the license lease in the Keychain and verifies the machine-file's
/// Ed25519 signature against the embedded Keygen public key before trusting it.
///
/// The signature is verified on every read, not on write: a check-out arrives
/// over TLS and is trusted when stored, but a cached blob an attacker edits
/// offline to fake "valid" must be rejected on load — so `load()` re-verifies
/// and returns `nil` for a tampered file.
internal struct StowerLicenseLeaseStore: Sendable {
    private let storage: StowerLeaseStorage
    private let publicKeyHex: String

    /// Creates a lease store.
    ///
    /// - Parameters:
    ///   - storage: The persistence seam; defaults to the Keychain item. Injected
    ///     so tests use an in-memory blob.
    ///   - publicKeyHex: The Keygen account's Ed25519 public key as hex; injected
    ///     so the signature-verification tests can sign with a known key. Defaults
    ///     to the embedded production key.
    internal init(
        storage: StowerLeaseStorage = StowerKeychainItem(
            service: leaseKeychainService,
            account: leaseKeychainAccount
        ),
        publicKeyHex: String = StowerLicenseLeaseStore.keygenPublicKeyHex
    ) {
        self.storage = storage
        self.publicKeyHex = publicKeyHex
    }

    /// Persists `lease`; returns whether the write succeeded.
    @discardableResult
    internal func save(_ lease: StowerLicenseLease) -> Bool {
        guard let data = try? JSONEncoder().encode(lease) else { return false }
        return storage.write(data)
    }

    /// Loads the lease, or `nil` when none is stored, the blob is corrupt, or the
    /// machine-file's signature fails to verify (a tampered cache).
    internal func load() -> StowerLicenseLease? {
        guard let data = storage.readData(),
            let lease = try? JSONDecoder().decode(StowerLicenseLease.self, from: data),
            verifyMachineFile(lease.machineFile)
        else {
            return nil
        }
        return lease
    }

    /// Removes any stored lease.
    internal func clear() {
        storage.delete()
    }

    /// Verifies a machine-file's Ed25519 signature against the embedded public key.
    ///
    /// The signed payload is `"machine/" + enc` per Keygen's cryptography spec; a
    /// missing/unparseable certificate or a bad signature is `false`.
    internal func verifyMachineFile(_ machineFile: String) -> Bool {
        guard let publicKeyData = Self.data(fromHex: publicKeyHex),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
            let certificate = Self.parseCertificate(machineFile),
            let signature = Data(base64Encoded: certificate.sig)
        else {
            return false
        }
        let signedData = Data((Self.signingPrefix + certificate.enc).utf8)
        return publicKey.isValidSignature(signature, for: signedData)
    }

    /// Strips the PEM envelope, base64-decodes the body, and decodes the
    /// `{enc, sig, alg}` certificate, or `nil` when any step fails.
    private static func parseCertificate(_ machineFile: String) -> StowerMachineCertificate? {
        let body =
            machineFile
            .replacingOccurrences(of: beginMarker, with: "")
            .replacingOccurrences(of: endMarker, with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let decoded = Data(base64Encoded: body),
            let certificate = try? JSONDecoder().decode(
                StowerMachineCertificate.self,
                from: decoded
            )
        else {
            return nil
        }
        return certificate
    }

    /// Decodes an even-length hex string to bytes, or `nil` on a bad digit.
    private static func data(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static let signingPrefix = "machine/"
    private static let beginMarker = "-----BEGIN MACHINE FILE-----"
    private static let endMarker = "-----END MACHINE FILE-----"
    private static let leaseKeychainService = "com.stower.license.lease"
    private static let leaseKeychainAccount = "machine-file"

    /// The Stower Keygen account's Ed25519 public key (hex), used to verify a
    /// machine-file offline.
    ///
    /// Replaced with the real account key when Plan B wires the gate; the all-zero
    /// placeholder verifies nothing, which is correct for this board-independent
    /// slice (no production verification runs yet).
    internal static let keygenPublicKeyHex =
        "0000000000000000000000000000000000000000000000000000000000000000"
}

/// The minimal decode of a Keygen machine-file certificate.
///
/// Holds the encoded payload, its signature, and the algorithm; only `enc`/`sig`
/// drive verification.
private struct StowerMachineCertificate: Decodable {
    let enc: String
    let sig: String
    let alg: String
}
