import Foundation

/// The production `StowerLicenseGating`: composes the online check-in client, the
/// signed-lease Keychain store, and the install fingerprint into the gate the
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
    private let fingerprint: StowerKeychainFingerprint

    /// Creates a gate from its three collaborators; injectable so tests pass a spy
    /// client, an in-memory lease store keyed with a known signing key, and a
    /// fixed fingerprint.
    internal init(
        client: any StowerLicenseCheckInProviding,
        leaseStore: StowerLicenseLeaseStore,
        fingerprint: StowerKeychainFingerprint
    ) {
        self.client = client
        self.leaseStore = leaseStore
        self.fingerprint = fingerprint
    }

    /// Builds the production gate wired to the Edge Function, the Keychain lease
    /// store, and the real install fingerprint.
    ///
    /// Endpoints + the Keygen public key come from `StowerLicenseConfig.resolved`
    /// (staging in DEBUG, production otherwise, with `STOWER_*` env overrides applied
    /// in DEBUG only — Release pins the compiled config). In a Release build before
    /// prod ops fills the `production` defaults (G10), the online calls are
    /// unreachable and a first run lands on `.connectOnce`.
    ///
    /// In a DEBUG build the `StowerLicenseDebugArguments` launch-arg seam can clear
    /// the lease (`--clear-lease-on-start`) and pin the fingerprint
    /// (`--fingerprint <value>`) before the gate runs; the whole seam is
    /// compile-stripped from Release.
    internal init() {
        let config = StowerLicenseConfig.resolved
        let leaseStore = StowerLicenseLeaseStore(publicKeyHex: config.keygenPublicKeyHex)
        let fingerprint: StowerKeychainFingerprint
        #if DEBUG
            switch StowerLicenseDebugArguments.parse(CommandLine.arguments) {
            case .failure(.missingValue(let flag)):
                // A malformed debug arg is a deterministic refusal, not a crash: name
                // the flag on stderr (the one permitted diagnostic — a static flag
                // name, no key/PII) and exit BEFORE the gate runs, so a typo can't
                // silently no-op. `exit` returns Never, so `fingerprint` stays
                // definitely-assigned on every continuing path.
                let message = "stower: \(flag) requires a value — malformed debug launch argument\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(EXIT_FAILURE)
            case .success(let debug):
                if debug.clearLeaseOnStart { leaseStore.clear() }
                // Bind `override` by name — a bare `{ $0 }` would be a zero-arg
                // provider closure (a compile error that captures nothing).
                if let override = debug.fingerprintOverride {
                    fingerprint = StowerKeychainFingerprint(installUUID: { override })
                } else {
                    fingerprint = StowerKeychainFingerprint()
                }
            }
        #else
            fingerprint = StowerKeychainFingerprint()
        #endif
        self.init(
            client: StowerLicenseCheckInClient(functionBaseURL: config.functionBaseURL),
            leaseStore: leaseStore,
            fingerprint: fingerprint
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
            return refreshedStatus(machineFile: machineFile, lease: lease, now: now)
        case .trialExpired(let id):
            // Keep the cached lease: its licenseID feeds the paywall's Buy flow and the
            // post-purchase Re-check, and `hasLease()` staying true keeps the Re-check
            // copy correct ("Checking your license…", not "Starting your free trial…").
            // The offline re-entry this used to guard against — an expired trial's
            // machine-file TTL re-granting access offline — is now closed in the
            // `.unreachable` branch, which routes a past signed trial expiry to the
            // paywall (I14), so the lease no longer needs clearing here.
            return .trialExpired(licenseID: id)
        case .wrongVersion(let id):
            // Same reasoning as `.trialExpired`: the server has denied this build, so
            // drop the cached file rather than let its TTL re-authorize offline if the
            // client/server entitlement rules ever diverge.
            leaseStore.clear()
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
            // Offline fallback: the cached signed lease authorizes this build UNLESS the
            // trial has already ended. Because an online `.trialExpired` verdict no
            // longer clears the lease, the offline expiry boundary (I14) is enforced
            // HERE: the machine file's signed trial expiry is tamper-proof, so an expired
            // trial routes to the paywall and cannot be re-granted access by simply going
            // offline. A paid/perpetual license has a nil expiry and falls through.
            if let trialExpiry = leaseStore.trialExpiry(
                forMachineFile: lease.machineFile,
                licenseID: lease.licenseID
            ), trialExpiry <= now {
                return .trialExpired(licenseID: lease.licenseID)
            }
            return authorizes(machineFile: lease.machineFile, now: now)
                ? .valid : .couldNotReach
        }
    }

    /// Stores a fresh check-in `.ok` file and returns `.valid`, or `.couldNotReach`.
    ///
    /// Validates the fresh file in memory BEFORE overwriting the cached lease: a bad
    /// checkout must not destroy a still-valid offline lease, and a file the app
    /// cannot honor must not become a `.valid` it can't stand behind.
    private func refreshedStatus(
        machineFile: String,
        lease: StowerLicenseLease,
        now: Date
    ) -> StowerLicenseStatus {
        guard authorizes(machineFile: machineFile, now: now) else { return .couldNotReach }
        let refreshed = StowerLicenseLease(
            licenseKey: lease.licenseKey,
            licenseID: lease.licenseID,
            machineFile: machineFile,
            validatedAt: now
        )
        guard leaseStore.save(refreshed) else { return .couldNotReach }
        return .valid
    }

    /// Whether `machineFile` authorizes THIS build right now.
    ///
    /// True when it verifies (signature, I6), its machine-file TTL is in the future
    /// (I14), its entitlements allow this build (I5), and it was checked out for THIS
    /// device (the device match stops a file copied from another Mac). Pure decode —
    /// touches no storage, so a candidate check-out can be validated BEFORE it
    /// overwrites a still-valid cached lease. The trial's own expiry is not checked
    /// here; the callers that must enforce it do so explicitly — `mintFlow` and the
    /// offline `.unreachable` branch both route a past signed trial expiry to the
    /// paywall before trusting the file.
    private func authorizes(machineFile: String, now: Date) -> Bool {
        guard let authority = leaseStore.offlineAuthority(forMachineFile: machineFile, now: now),
            authority.allowsThisBuild,
            authority.matchesDevice(fingerprint.fingerprint())
        else {
            return false
        }
        return true
    }

    /// The shared mint path — the no-lease branch and the `unknown_license`
    /// self-heal both use it, so a 404 can never loop on a stored lease (it is
    /// cleared first).
    private func mintFlow(now: Date) async -> StowerLicenseStatus {
        switch await client.mint(fingerprint: fingerprint.fingerprint()) {
        case .minted(let licenseKey, let licenseID, let machineFile):
            // Do not blind-trust the mint reply, and validate from the file itself
            // BEFORE storing so an expired/unauthorized reply never overwrites state.
            // The Edge Function reuses an existing trial row for a known fingerprint
            // (handlers.ts `mintTrial`), so an already-expired trial comes back as a
            // signed file with no `expired` verdict: a past signed license expiry
            // routes to the paywall (never stored, so no machine-file TTL re-grants it
            // offline). A paid/perpetual license carries a nil expiry and passes.
            let signedExpiry = leaseStore.trialExpiry(
                forMachineFile: machineFile,
                licenseID: licenseID
            )
            if let signedExpiry, signedExpiry <= now {
                return .trialExpired(licenseID: licenseID)
            }
            // Hold the minted file to the same bar as a check-in `.ok` — it must
            // verify, authorize this build, and be bound to this device — then store.
            guard authorizes(machineFile: machineFile, now: now) else {
                return .couldNotReach
            }
            let lease = StowerLicenseLease(
                licenseKey: licenseKey,
                licenseID: licenseID,
                machineFile: machineFile,
                validatedAt: now
            )
            guard leaseStore.save(lease) else { return .couldNotReach }
            return .valid
        case .retryShortly:
            return .couldNotReach
        case .unreachable:
            return .needsTrialOnline
        }
    }
}
