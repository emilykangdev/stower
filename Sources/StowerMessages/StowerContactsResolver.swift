import Contacts
import Foundation

/// An immutable handle-to-display-name lookup built from Contacts.
public struct StowerContactsResolver: Sendable {
    private let exactNames: [String: String]
    private let suffixNames: [String: String?]

    /// Builds a resolver from raw handle-to-name entries.
    public init(mapping: [String: String] = [:]) {
        var exactNames: [String: String] = [:]
        var suffixCandidates: [String: Set<String>] = [:]
        for (handle, name) in mapping {
            if let emailKey = StowerPhoneNormalizer.emailKey(for: handle) {
                exactNames[emailKey] = name
            }
            if let exactKey = StowerPhoneNormalizer.exactPhoneKey(for: handle) {
                exactNames[exactKey] = name
            }
            if let suffixKey = StowerPhoneNormalizer.suffixPhoneKey(for: handle) {
                suffixCandidates[suffixKey, default: []].insert(name)
            }
        }
        self.exactNames = exactNames
        suffixNames = suffixCandidates.mapValues { names in
            names.count == 1 ? names.first : nil
        }
    }

    /// Returns a contact name or the original handle when no unambiguous match exists.
    public func displayName(for handle: String) -> String {
        let emailKey = StowerPhoneNormalizer.emailKey(for: handle)
        if let emailKey, let name = exactNames[emailKey] {
            return name
        }
        let exactKey = StowerPhoneNormalizer.exactPhoneKey(for: handle)
        if let exactKey, let name = exactNames[exactKey] {
            return name
        }
        let suffixKey = StowerPhoneNormalizer.suffixPhoneKey(for: handle)
        if let suffixKey, let candidate = suffixNames[suffixKey], let name = candidate {
            return name
        }
        return handle
    }

    /// Resolves a normalized handle KEY (`StowerDraftKey.derive` form) to a name.
    ///
    /// The muted-senders popover keys on the normalized handle (the only identity it
    /// stores), but the rows are NOT on the board, so their names can't be read from
    /// loaded rows. The resolver's exact index is keyed by the SAME normalized form
    /// `StowerDraftKey.derive` produces (both go through `StowerPhoneNormalizer`), so a
    /// key lookup is a direct hit; an unmatched key degrades to a readable handle
    /// (the de-prefixed key), never the raw `e164:`/`email:`/`raw:` token.
    ///
    /// - Parameter key: A normalized handle key (`email:…` / `e164:…` / `raw:…`).
    /// - Returns: The Contacts name, or a readable handle fallback.
    public func displayName(forKey key: String) -> String {
        if let name = exactNames[key] {
            return name
        }
        return Self.readableHandle(forKey: key)
    }

    /// Whether a normalized key resolves to a real Contacts name (vs a handle
    /// fallback) — drives the muted-senders avatar (initials vs a generic glyph).
    ///
    /// - Parameter key: A normalized handle key (`email:…` / `e164:…` / `raw:…`).
    /// - Returns: `true` when a Contacts name exists for the key.
    public func hasName(forKey key: String) -> Bool {
        exactNames[key] != nil
    }

    /// Reconstructs a readable handle from a normalized key for display fallback.
    ///
    /// `e164:14155550100` → `+14155550100`, `email:a@b.com` → `a@b.com`,
    /// `raw:foo` → `foo`. Display-only — never used as a key.
    private static func readableHandle(forKey key: String) -> String {
        if key.hasPrefix(e164KeyPrefix) {
            return "+" + key.dropFirst(e164KeyPrefix.count)
        }
        if key.hasPrefix(emailKeyPrefix) {
            return String(key.dropFirst(emailKeyPrefix.count))
        }
        if key.hasPrefix(rawKeyPrefix) {
            return String(key.dropFirst(rawKeyPrefix.count))
        }
        return key
    }

    /// The normalized-key prefixes, used only to de-prefix a key for display fallback.
    ///
    /// They mirror `StowerPhoneNormalizer` / `StowerDraftKey`'s forward derivation.
    private static let e164KeyPrefix = "e164:"
    private static let emailKeyPrefix = "email:"
    private static let rawKeyPrefix = "raw:"

    /// Builds a resolver from Contacts when access is already authorized.
    public static func live() -> StowerContactsResolver {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return StowerContactsResolver()
        }
        do {
            return StowerContactsResolver(mapping: try contactMapping())
        } catch {
            return StowerContactsResolver()
        }
    }

    private static func contactMapping() throws -> [String: String] {
        let store = CNContactStore()
        let formatterKey = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        var keys = [formatterKey]
        keys.append(CNContactOrganizationNameKey as CNKeyDescriptor)
        keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor)
        keys.append(CNContactEmailAddressesKey as CNKeyDescriptor)
        let request = CNContactFetchRequest(keysToFetch: keys)
        var mapping: [String: String] = [:]
        try store.enumerateContacts(with: request) { contact, _ in
            guard let name = contactDisplayName(contact) else {
                return
            }
            for phoneNumber in contact.phoneNumbers {
                mapping[phoneNumber.value.stringValue] = name
            }
            for emailAddress in contact.emailAddresses {
                mapping[emailAddress.value as String] = name
            }
        }
        return mapping
    }

    private static func contactDisplayName(_ contact: CNContact) -> String? {
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)
        if let fullName, !fullName.isEmpty {
            return fullName
        }
        return contact.organizationName.isEmpty ? nil : contact.organizationName
    }
}
