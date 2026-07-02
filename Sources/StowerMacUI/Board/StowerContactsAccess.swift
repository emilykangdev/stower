import Contacts
import Foundation

/// App-owned Contacts authorization, so views/view-models never import `Contacts`.
///
/// Collapses the system states into the three the UI actually branches on: a
/// `denied` here also covers `.restricted` (both recover only through System
/// Settings, never an in-app prompt).
internal enum StowerContactsAuthorization: Sendable {
    /// Access granted — names resolve.
    case authorized

    /// Never asked — an in-app tap can still raise the one system prompt.
    case notDetermined

    /// Refused or restricted — the system never re-prompts; recovery is System
    /// Settings → Privacy → Contacts.
    case denied
}

/// Thrown when `requestAccess` never delivers a completion.
///
/// Observed on real hardware (`Docs/Permissions.md`) as a client-side hang in
/// the OS permissions layer: no XPC send, no permission-daemon record, ever.
/// Distinct from a `false` grant so the caller can release its UI latch
/// instead of waiting forever, without discarding a legitimately late answer
/// (see `requestAccessIfNeeded(onLateResult:)`).
internal enum StowerContactsAccessError: Error, Sendable {
    case timedOut
}

/// The one isolated wrapper over Contacts authorization for the app.
///
/// Mirrors `StowerSystemSettingsOpener`'s injection shape: the system calls are
/// `@Sendable` closures defaulted to the real `CNContactStore`, so previews and
/// tests inject a scripted status + request and never touch the real address book.
/// It imports only `Contacts` (never `StowerMessages`), so it stays outside the
/// engine-import boundary; resolution itself happens in the engine-coupled
/// `StowerLiveBoardDataSource` via `StowerContactsResolver.live()`.
///
/// Contacts is never a gate: a denied/restricted store degrades the board to raw
/// handles, matching the engine's existing "denial degrades, never errors" contract.
internal struct StowerContactsAccess: Sendable {
    private let status: @Sendable () -> CNAuthorizationStatus
    private let request: @MainActor @Sendable () async -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Coalesces overlapping `requestAccessIfNeeded` calls onto the single real
    /// `request()` in flight, so a "Try Again" tap after a timeout joins the
    /// abandoned OS call instead of firing a second one. `StowerContactsAccess`
    /// is a value type recreated per call site, but this reference is shared
    /// across every copy (all trace back to one `init`), matching the real
    /// constraint: only one `CNContactStore.requestAccess` should ever be
    /// outstanding per process.
    private let inFlight: StowerContactsInFlightRequest

    /// How long to wait for `requestAccess` before treating it as wedged.
    ///
    /// See `Docs/Permissions.md` for the observed hang this bounds.
    private static let requestTimeout: Duration = .seconds(10)

    /// Creates a Contacts-access wrapper.
    ///
    /// `status` reads the process-wide authorization (never prompts); `request`
    /// shows the one system permission dialog; `sleep` bounds how long
    /// `requestAccessIfNeeded` waits on it. All three default to the real
    /// `CNContactStore`/`Task.sleep` and are injectable so tests assert behavior
    /// without touching the real address book or a real clock.
    ///
    /// `request` is pinned to `@MainActor`: `CNContactStore.requestAccess`'s reply
    /// is delivered relative to the calling thread's run loop, and Swift
    /// Concurrency's background executor threads don't run one. Off the main
    /// thread the completion silently never fires — no throw, no prompt, no
    /// permission record — which reads as a permanent hang, not an error.
    internal init(
        status: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        request: @escaping @MainActor @Sendable () async -> Bool = {
            let store = CNContactStore()
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                store.requestAccess(for: .contacts) { granted, _ in
                    withExtendedLifetime(store) {}
                    cont.resume(returning: granted)
                }
            }
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.status = status
        self.request = request
        self.sleep = sleep
        self.inFlight = StowerContactsInFlightRequest()
    }

    /// A denied no-op access for previews and tests, so they never prompt.
    ///
    /// The board stays on handles. Keeps `CNAuthorizationStatus` out of the view
    /// layer: the VM and root view reference this instead of a `Contacts` enum literal.
    internal static let denied = StowerContactsAccess(status: { .denied }, request: { false })

    /// The current authorization, collapsed into the app-owned three-state.
    ///
    /// A bare read; never prompts. `.restricted` collapses into `.denied` (both
    /// recover only via System Settings); any future/unknown case is treated as
    /// `.denied` so the UI offers the Settings path rather than a prompt that
    /// can't succeed.
    internal var authorization: StowerContactsAuthorization {
        switch status() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Whether Contacts is currently authorized (a bare read; never prompts).
    internal var isAuthorized: Bool { authorization == .authorized }

    /// Requests access only when undetermined, returning the resulting authorized-ness.
    ///
    /// Authorized short-circuits to `true`; denied/restricted short-circuit to
    /// `false` and never re-prompt; only `.notDetermined` shows the system dialog,
    /// raced against `requestTimeout`.
    ///
    /// - Parameter onLateResult: Invoked with the grant, on the main actor, if
    ///   `requestAccess` finally completes AFTER this call already threw
    ///   `.timedOut` — the underlying OS call cannot be cancelled (see
    ///   `raceRequestAgainstTimeout`), so a late real answer is reported here
    ///   instead of being silently discarded. Never invoked on the happy path.
    /// - Returns: `true` iff Contacts is authorized after this call.
    /// - Throws: `StowerContactsAccessError.timedOut` if `requestAccess` neither
    ///   completed nor could be waited on within `requestTimeout`.
    internal func requestAccessIfNeeded(
        onLateResult: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) async throws -> Bool {
        switch status() {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return try await raceRequestAgainstTimeout(onLateResult: onLateResult)
        }
    }

    /// Resumes a single continuation with whichever of the shared in-flight
    /// `request()` or this call's own timeout settles first.
    ///
    /// Deliberately not a `TaskGroup`/`async let` race: both implicitly await
    /// every child task before returning, so even after "cancelling" the
    /// loser, a `request()` stuck inside an uncancellable
    /// `withCheckedContinuation` would still block this function forever —
    /// exactly the hang this exists to fix. Instead the timeout runs as an
    /// unstructured `@MainActor` `Task` racing against `inFlight`, which owns
    /// the actual `request()` call across every caller (see its doc comment):
    /// a wedged `request()` is genuinely abandoned by THIS call, never
    /// awaited, but stays alive for a later "Try Again" to join instead of
    /// starting a second real `CNContactStore.requestAccess`.
    private func raceRequestAgainstTimeout(
        onLateResult: (@MainActor @Sendable (Bool) -> Void)?
    ) async throws -> Bool {
        let request = self.request
        let sleep = self.sleep
        let inFlight = self.inFlight
        return try await withCheckedThrowingContinuation { continuation in
            let box = StowerContactsRequestBox(
                continuation: continuation,
                onLateResult: onLateResult
            )
            Task { @MainActor in
                inFlight.join(box: box, request: request)
            }
            Task { @MainActor in
                do {
                    try await sleep(Self.requestTimeout)
                    box.fireTimeout()
                } catch {
                    // The sleep was interrupted before genuinely timing out
                    // (e.g. cancellation) — not a real wedge, so don't report
                    // one. `inFlight` is unaffected and keeps waiting on the
                    // real `request()` regardless of this call's own outcome.
                }
            }
        }
    }
}

/// Owns the single real `request()` call in flight, so every
/// `requestAccessIfNeeded` caller — including a "Try Again" tap after a prior
/// call already timed out — joins the SAME abandoned OS call instead of
/// starting a second one.
///
/// `CNContactStore` only ever has one prompt outstanding per process; two
/// overlapping `requestAccess` calls have been observed (`Docs/Permissions.md`)
/// to leave the permission daemon's own prompt queue stuck rather than each
/// resolving independently. `@MainActor`-isolated to match `request`'s
/// run-loop requirement and to serialize access to `waiters`/`isRunning`
/// without a lock.
@MainActor
private final class StowerContactsInFlightRequest {
    private var waiters: [StowerContactsRequestBox] = []
    private var isRunning = false

    /// Registers `box` to receive the outcome of the single outstanding
    /// `request()` call, starting it only if none is running yet.
    func join(
        box: StowerContactsRequestBox,
        request: @escaping @MainActor @Sendable () async -> Bool
    ) {
        waiters.append(box)
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            let granted = await request()
            self.isRunning = false
            let pending = self.waiters
            self.waiters = []
            for waiter in pending {
                waiter.resolve(granted)
            }
        }
    }
}

/// Resumes a `requestAccessIfNeeded` continuation exactly once.
///
/// Settles with whichever of `request()` or the timeout finishes first, and
/// reports a later `request()` answer through `onLateResult` instead of
/// discarding it. `@MainActor`-isolated so the two racing `Task`s in
/// `raceRequestAgainstTimeout` can share this mutable state without a lock —
/// both are themselves pinned to the main actor to satisfy `request`'s
/// run-loop requirement, so calls into this box are already serialized.
@MainActor
private final class StowerContactsRequestBox {
    private var continuation: CheckedContinuation<Bool, Error>?
    private var timedOut = false
    private let onLateResult: (@MainActor @Sendable (Bool) -> Void)?

    nonisolated init(
        continuation: CheckedContinuation<Bool, Error>,
        onLateResult: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        self.continuation = continuation
        self.onLateResult = onLateResult
    }

    func resolve(_ granted: Bool) {
        guard let continuation else {
            // Already gave up waiting (timed out) — request() answered anyway;
            // honor the real decision instead of discarding it.
            if timedOut { onLateResult?(granted) }
            return
        }
        self.continuation = nil
        continuation.resume(returning: granted)
    }

    func fireTimeout() {
        guard let continuation else { return }
        self.continuation = nil
        timedOut = true
        continuation.resume(throwing: StowerContactsAccessError.timedOut)
    }
}
