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
