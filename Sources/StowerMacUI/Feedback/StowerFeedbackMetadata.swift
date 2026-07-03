import Foundation

/// The three silent context fields attached to a feedback submission, assembled
/// once from one source of truth each: `instanceID` from `StowerLicenseStore`,
/// the version string from `Bundle.main`, the OS string from `ProcessInfo`.
///
/// The license `key` is never read here — only the opaque `instanceID` (JC1).
/// Nothing is logged.
internal struct StowerFeedbackMetadata: Sendable, Equatable {
    /// The opaque Lemon Squeezy instance id, or `nil` for a trial/unlicensed user.
    internal let instanceID: String?

    /// The user's coarse license status.
    internal let licenseStatus: StowerFeedbackLicenseStatus

    /// The app version, e.g. `"1.0 (1)"`.
    internal let appVersion: String

    /// The OS version, e.g. `"macOS 15.4"`.
    ///
    /// The synthesized memberwise initializer is used directly by tests to pass
    /// fixed strings.
    internal let osVersion: String

    /// Assembles the live metadata from injectable readers.
    ///
    /// `instanceID` is read from the stored license (`nil` on trial/unlicensed).
    /// `licenseStatus` is `.trial` while on trial; otherwise `.paid` if an
    /// instance id is present, else the defensive `.unlicensed`. The `bundle`
    /// and `processInfo` readers are injected so `swift test` (where `Bundle.main`
    /// is the test runner, not StowerMac) can pass fixed strings.
    ///
    /// - Parameters:
    ///   - isOnTrial: Whether the user is currently on an active trial.
    ///   - licenseStore: The stored-license reader; source of `instanceID`.
    ///   - bundle: The app-version reader; defaults to `Bundle.main`.
    ///   - processInfo: The OS-version reader; defaults to `ProcessInfo.processInfo`.
    /// - Returns: The assembled metadata.
    internal static func current(
        isOnTrial: Bool,
        licenseStore: StowerLicenseStore = StowerLicenseStore(),
        bundle: StowerFeedbackBundleReading = Bundle.main,
        processInfo: StowerFeedbackOSReading = ProcessInfo.processInfo
    ) -> StowerFeedbackMetadata {
        let instanceID = licenseStore.read()?.instanceID
        let status: StowerFeedbackLicenseStatus =
            isOnTrial ? .trial : (instanceID != nil ? .paid : .unlicensed)
        return StowerFeedbackMetadata(
            instanceID: instanceID,
            licenseStatus: status,
            appVersion: bundle.stowerVersionString,
            osVersion: processInfo.stowerOSVersionString
        )
    }
}

/// The app-version reader seam — `Bundle.main` in the app, a fixed fake in tests.
internal protocol StowerFeedbackBundleReading: Sendable {
    /// The marketing + build version, formatted `"1.0 (1)"`.
    var stowerVersionString: String { get }
}

/// The OS-version reader seam — `ProcessInfo.processInfo` in the app, a fixed
/// fake in tests.
internal protocol StowerFeedbackOSReading: Sendable {
    /// The OS version, formatted `"macOS 15.4"`.
    var stowerOSVersionString: String { get }
}

extension Bundle: StowerFeedbackBundleReading {
    /// `"<CFBundleShortVersionString> (<CFBundleVersion>)"`, each falling back to
    /// `"?"` if absent (never force-unwrapped).
    internal var stowerVersionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

extension ProcessInfo: StowerFeedbackOSReading {
    /// `"macOS <major>.<minor>.<patch>"` (patch dropped when zero), from
    /// `operatingSystemVersion`.
    internal var stowerOSVersionString: String {
        let version = operatingSystemVersion
        let base = "macOS \(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }
}
