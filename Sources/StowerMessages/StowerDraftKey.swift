import Foundation

/// Derives the stable, conversation-identifying key a draft is stored under.
///
/// A draft is precious and must survive the things that churn in `chat.db`: the
/// chat GUID flips on an SMS<->iMessage switch, and the Contacts card mutates
/// freely. The normalized handle is the most stable identity available, so the
/// draft is keyed on it — never on `chat.guid` or a resolved name.
///
/// The result is one of three prefixed forms, in priority order:
/// - `email:<lowercased address>` for a handle containing `@`,
/// - `e164:<digits>` for a `+`-prefixed phone number (note: NO `+`, and only when
///   the handle starts with `+`),
/// - `raw:<trimmed handle>` for anything else (a bare number, a service id).
///
/// It reuses `StowerPhoneNormalizer` (intra-module) and deliberately never calls
/// `suffixPhoneKey`: a `phone10:` suffix match would merge two different people who
/// share the last ten digits, mis-assigning a draft.
public enum StowerDraftKey {
    /// The prefix for a handle that matched neither the email nor the e164 rule.
    private static let rawPrefix = "raw:"

    /// Derives the draft key for a conversation's counterpart handle.
    ///
    /// - Parameter handle: The counterpart's raw identifier (phone, email, or a
    ///   service id), exactly as it appears on the row.
    /// - Returns: A stable, prefixed draft key. Pure and deterministic: the same
    ///   handle always derives the same key, so a `+`-variant of one number never
    ///   splits into two drafts.
    public static func derive(forHandle handle: String) -> String {
        if let emailKey = StowerPhoneNormalizer.emailKey(for: handle) {
            return emailKey
        }
        if let phoneKey = StowerPhoneNormalizer.exactPhoneKey(for: handle) {
            return phoneKey
        }
        return rawPrefix + handle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
