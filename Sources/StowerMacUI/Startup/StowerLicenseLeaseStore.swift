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
        // Update the existing item in place; add only when none exists. A plain
        // delete-then-add would destroy a valid stored lease if the add then failed
        // (a transient Keychain error), losing the offline authority. delete() stays
        // reserved for an explicit clear().
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
    ///   - publicKeyHex: The Keygen account's Ed25519 public key as hex. The
    ///     production gate supplies `StowerLicenseConfig.resolved.keygenPublicKeyHex`;
    ///     tests inject a known key so they can sign their own machine files.
    internal init(
        storage: StowerLeaseStorage = StowerKeychainItem(
            service: leaseKeychainService,
            account: leaseKeychainAccount
        ),
        publicKeyHex: String
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

    /// The signed offline authority for the cached lease, or `nil` when there is no
    /// lease or it does not decode/verify (delegates to the machine-file form).
    internal func offlineAuthority(now: Date) -> StowerOfflineAuthority? {
        guard let lease = load() else { return nil }
        return offlineAuthority(forMachineFile: lease.machineFile, now: now)
    }

    /// The signed offline authority for an arbitrary `machineFile`, or `nil` when its
    /// signature fails (I6), its `enc` won't decode, or its TTL (`meta.expiry`) is
    /// at/behind `now` (I14 — no grace).
    ///
    /// Verifies the signature itself (the file may be a fresh check-out not yet
    /// stored), so the gate can validate a candidate BEFORE it overwrites a valid
    /// cached lease. The caller still checks `allowsThisBuild` (the entitlement OR,
    /// I5).
    internal func offlineAuthority(
        forMachineFile machineFile: String,
        now: Date
    ) -> StowerOfflineAuthority? {
        guard verifyMachineFile(machineFile),
            let payload = Self.decodePayload(machineFile),
            let expiry = Self.parseExpiry(payload.meta.expiry),
            expiry > now
        else {
            return nil
        }
        let codes = payload.included
            .filter { $0.type == Self.entitlementsType }
            .compactMap { $0.attributes?.code }
        return StowerOfflineAuthority(
            machineFileExpiry: expiry,
            entitlementCodes: codes,
            machineFingerprint: payload.data?.attributes?.fingerprint
        )
    }

    /// The trial end date from the cached lease's signed machine file, matched by
    /// `licenseID` (delegates to the machine-file form).
    internal func trialExpiry(forLicenseID id: String) -> Date? {
        guard let lease = load() else { return nil }
        return trialExpiry(forMachineFile: lease.machineFile, licenseID: id)
    }

    /// The trial end date from an arbitrary signed `machineFile`, matched by
    /// `licenseID` — the `included[licenses][id].attributes.expiry`.
    ///
    /// `nil` when the signature fails, the license entry is missing, or its expiry is
    /// null (the paid/perpetual case — the caller treats nil as "no active trial").
    /// `meta.expiry` (the TTL) is never used here.
    internal func trialExpiry(forMachineFile machineFile: String, licenseID id: String) -> Date? {
        guard verifyMachineFile(machineFile),
            let payload = Self.decodePayload(machineFile),
            let entry = payload.included.first(where: {
                $0.type == Self.licensesType && $0.id == id
            }),
            let isoString = entry.attributes?.expiry
        else {
            return nil
        }
        return Self.parseExpiry(isoString)
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

    /// Decodes the machine file's signed `enc` payload into a TTL + entitlement view.
    ///
    /// Returns `nil` when any step (certificate parse, base64, JSON) fails.
    private static func decodePayload(_ machineFile: String) -> StowerMachineFilePayload? {
        guard let certificate = parseCertificate(machineFile),
            let encData = Data(base64Encoded: certificate.enc),
            let payload = try? JSONDecoder().decode(StowerMachineFilePayload.self, from: encData)
        else {
            return nil
        }
        return payload
    }

    /// Parses a Keygen `meta.expiry` ISO-8601 timestamp (with or without
    /// fractional seconds), or `nil` when unparseable.
    private static func parseExpiry(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
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
    private static let entitlementsType = "entitlements"
    private static let licensesType = "licenses"
}

/// The signed offline-gate data decoded from the verified machine file's `enc`
/// payload: the TTL boundary (`meta.expiry`, I14) and the entitlement codes
/// (`included[entitlements].code`, I5).
///
/// Both come from the Ed25519-signed payload, so the offline OR + TTL check read
/// tamper-proof data — never an unsigned local flag.
internal struct StowerOfflineAuthority: Sendable, Equatable {
    /// The machine-file TTL boundary, decoded from the signed `meta.expiry`.
    internal let machineFileExpiry: Date

    /// The signed entitlement codes carried in the machine file.
    internal let entitlementCodes: [String]

    /// The device fingerprint the file was checked out for, decoded from the signed
    /// `data.attributes.fingerprint`, or `nil` when the signed payload omits it.
    internal let machineFingerprint: String?

    /// Whether the signed entitlements allow this build to run offline — the OR
    /// over `STOWER_TRIAL` / `STOWER_V0` (I5).
    ///
    /// A signed `STOWER_V0`-only lease can still fail this on a future build whose
    /// required code it lacks.
    internal var allowsThisBuild: Bool {
        entitlementCodes.contains(Self.trialEntitlementCode)
            || entitlementCodes.contains(Self.v0EntitlementCode)
    }

    /// Whether the signed machine file was checked out for `deviceFingerprint`.
    ///
    /// A genuine Keygen machine file carries the device it was issued to in the
    /// signed `data.attributes.fingerprint`, so a file copied to another Mac fails
    /// this — closing the offline trial-sharing path. A `nil` signed fingerprint
    /// does not block: an attacker cannot strip `data` from a signed file without
    /// breaking its Ed25519 signature (so any replayable genuine file always carries
    /// it), and failing open keeps the offline path working if the field is absent.
    internal func matchesDevice(_ deviceFingerprint: String) -> Bool {
        guard let machineFingerprint else { return true }
        return machineFingerprint == deviceFingerprint
    }

    private static let trialEntitlementCode = "STOWER_TRIAL"
    private static let v0EntitlementCode = "STOWER_V0"
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

/// The slice of a Keygen machine-file `enc` payload the offline gate reads: the
/// `meta.expiry` TTL boundary and the `included` entitlement codes and license
/// expiry.
private struct StowerMachineFilePayload: Decodable {
    struct Meta: Decodable {
        let expiry: String
    }

    /// The primary `data` resource of a machine file — the machine document.
    ///
    /// Its `attributes.fingerprint` is the device the file was checked out for; the
    /// offline gate matches it against this Mac so a signed file copied from another
    /// device cannot grant offline access here.
    struct MachineData: Decodable {
        let attributes: Attributes?
    }

    struct Included: Decodable {
        /// The resource type, e.g. `"entitlements"` or `"licenses"`.
        let type: String

        /// The Keygen resource id — used to match the correct license entry by id.
        let id: String?

        let attributes: Attributes?
    }

    struct Attributes: Decodable {
        /// The entitlement code, present on `type == "entitlements"` entries.
        let code: String?

        /// The license expiry ISO-8601 timestamp, present on `type == "licenses"`
        /// entries when the license is on an active trial; `nil` once paid (perpetual).
        let expiry: String?

        /// The device fingerprint, present on the machine `data.attributes`; the
        /// offline gate matches it against this Mac.
        let fingerprint: String?
    }

    let data: MachineData?
    let meta: Meta
    let included: [Included]
}
