import Contacts
import Foundation

/// The one isolated wrapper over Contacts authorization for the app.
///
/// Mirrors `StowerSystemSettingsOpener`'s injection shape: the two system calls are
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
    private let request: @Sendable () async -> Bool

    /// Creates a Contacts-access wrapper.
    ///
    /// `status` reads the process-wide authorization (never prompts); `request`
    /// shows the one system permission dialog. Both default to the real
    /// `CNContactStore` and are injectable so tests assert behavior without it.
    internal init(
        status: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        request: @escaping @Sendable () async -> Bool = {
            ((try? await CNContactStore().requestAccess(for: .contacts)) ?? false)
        }
    ) {
        self.status = status
        self.request = request
    }

    /// A denied no-op access for previews and tests, so they never prompt.
    ///
    /// The board stays on handles. Keeps `CNAuthorizationStatus` out of the view
    /// layer: the VM and root view reference this instead of a `Contacts` enum literal.
    internal static let denied = StowerContactsAccess(status: { .denied }, request: { false })

    /// Whether Contacts is currently authorized (a bare read; never prompts).
    internal var isAuthorized: Bool { status() == .authorized }

    /// Requests access only when undetermined, returning the resulting authorized-ness.
    ///
    /// Authorized short-circuits to `true`; denied/restricted short-circuit to
    /// `false` and never re-prompt; only `.notDetermined` shows the system dialog.
    /// - Returns: `true` iff Contacts is authorized after this call.
    internal func requestAccessIfNeeded() async -> Bool {
        switch status() {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return await request()
        }
    }
}
