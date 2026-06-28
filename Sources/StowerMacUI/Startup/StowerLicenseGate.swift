import Foundation

/// The production `StowerLicenseGating`: composes the online check-in client, the
/// signed-lease Keychain store, and the device fingerprint into the gate the
/// startup model drives.
///
/// `currentStatus` is the one branching point — a reachable JC5-signed `/check-in`
/// when a lease exists (storing the fresh signed file it returns), mint-on-first-
/// run otherwise, and a signed-lease offline fallback bounded by the machine
/// file's `meta.expiry` (I14) and its signed entitlement OR (I5). It owns no second
/// concurrency scheme — the startup model's generation token guards staleness.
internal struct StowerLicenseGate: StowerLicenseGating {
    private let client: any StowerLicenseCheckInProviding
    private let leaseStore: StowerLicenseLeaseStore
    private let fingerprint: StowerDeviceFingerprint

    /// Creates a gate from its three collaborators; injectable so tests pass a spy
    /// client, an in-memory lease store keyed with a known signing key, and a
    /// fixed fingerprint.
    internal init(
        client: any StowerLicenseCheckInProviding,
        leaseStore: StowerLicenseLeaseStore,
        fingerprint: StowerDeviceFingerprint
    ) {
        self.client = client
        self.leaseStore = leaseStore
        self.fingerprint = fingerprint
    }

    /// Builds the production gate wired to the Edge Function, the Keychain lease
    /// store, and the real device fingerprint.
    ///
    /// Endpoints + the Keygen public key come from `StowerLicenseConfig.resolved`
    /// (staging in DEBUG, production otherwise, with `STOWER_*` env overrides). In a
    /// Release build before prod ops fills the `production` defaults (G10), the
    /// online calls are unreachable and a first run lands on `.connectOnce`.
    internal init() {
        let config = StowerLicenseConfig.resolved
        self.init(
            client: StowerLicenseCheckInClient(functionBaseURL: config.functionBaseURL),
            leaseStore: StowerLicenseLeaseStore(publicKeyHex: config.keygenPublicKeyHex),
            fingerprint: StowerDeviceFingerprint()
        )
    }

    internal func hasLease() -> Bool {
        leaseStore.load() != nil
    }

    internal func trialBadge() -> StowerTrialBadge? {
        guard let lease = leaseStore.load(),
            let expiry = leaseStore.trialExpiry(forLicenseID: lease.licenseID)
        else {
            return nil
        }
        return StowerTrialBadge(licenseID: lease.licenseID, expiry: expiry)
    }

    internal func currentStatus(now: Date) async -> StowerLicenseStatus {
        guard let lease = leaseStore.load() else {
            return await mintFlow(now: now)
        }
        let result = await client.checkIn(
            licenseID: lease.licenseID,
            fingerprint: fingerprint.fingerprint(),
            licenseKey: lease.licenseKey
        )
        switch result {
        case .ok(let machineFile):
            let refreshed = StowerLicenseLease(
                licenseKey: lease.licenseKey,
                licenseID: lease.licenseID,
                machineFile: machineFile,
                validatedAt: now
            )
            // A failed Keychain write leaves no durable lease for next-launch
            // revalidation or the offline fallback; report the transient failure
            // rather than a `.valid` the app cannot honor past this session.
            guard leaseStore.save(refreshed) else { return .couldNotReach }
            return .valid
        case .trialExpired(let id):
            return .trialExpired(licenseID: id)
        case .wrongVersion(let id):
            return .wrongVersion(licenseID: id)
        case .unknownLicense:
            // 404 — the server has no row for our license id. Clear the stale lease
            // first so `hasLease()` flips false, THEN re-mint via the shared flow
            // (JC6 self-heal); leaving it stored would 404 every launch and loop.
            // Mint is fingerprint-idempotent server-side, so this can't grant a
            // second trial.
            leaseStore.clear()
            return await mintFlow(now: now)
        case .badSignature, .fingerprintMismatch:
            // 401 (transient — re-sign next launch) and 409 (device changed; PAR-36
            // owns the real UX) both degrade to a transient retry in Plan B.
            return .couldNotReach
        case .unreachable:
            return offlineStatus(now: now)
        }
    }

    /// The offline fallback when the check-in is unreachable.
    ///
    /// `.valid` while the signed lease's TTL is in the future (I14), its
    /// entitlements allow this build (I5), and it was checked out for THIS device —
    /// else `.couldNotReach`. The device match stops a signed file copied from
    /// another Mac from granting offline access here.
    private func offlineStatus(now: Date) -> StowerLicenseStatus {
        guard let authority = leaseStore.offlineAuthority(now: now),
            authority.allowsThisBuild,
            authority.matchesDevice(fingerprint.fingerprint())
        else {
            return .couldNotReach
        }
        return .valid
    }

    /// The shared mint path — the no-lease branch and the `unknown_license`
    /// self-heal both use it, so a 404 can never loop on a stored lease (it is
    /// cleared first).
    private func mintFlow(now: Date) async -> StowerLicenseStatus {
        switch await client.mint(fingerprint: fingerprint.fingerprint()) {
        case .minted(let licenseKey, let licenseID, let machineFile):
            let lease = StowerLicenseLease(
                licenseKey: licenseKey,
                licenseID: licenseID,
                machineFile: machineFile,
                validatedAt: now
            )
            guard leaseStore.save(lease) else { return .couldNotReach }
            // Do not blind-trust the mint reply. The Edge Function reuses an existing
            // trial row for a known fingerprint (handlers.ts `mintTrial`), so a device
            // whose trial already expired — relaunching after its local lease was
            // cleared — gets a signed file back with no `expired` verdict. Gate
            // `.valid` on the signed license expiry the file itself carries: a past
            // expiry routes to the paywall instead of silently re-entering the trial.
            // A paid/perpetual license carries a nil expiry and is allowed through.
            let signedExpiry = leaseStore.trialExpiry(forLicenseID: licenseID)
            if let signedExpiry, signedExpiry <= now {
                return .trialExpired(licenseID: licenseID)
            }
            return .valid
        case .retryShortly:
            return .couldNotReach
        case .unreachable:
            return .needsTrialOnline
        }
    }
}
