import Foundation

internal enum StowerMessageMapper {
    internal static func map(
        row: StowerSourceMessageRow,
        body: String?,
        participantHandles: [String],
        contacts: StowerContactsResolver
    ) -> StowerMessageItem? {
        guard row.associatedMessageType == 0, row.itemType == 0,
            let date = StowerMessageDate.date(from: row.rawDate),
            let body = cleanBody(body)
        else {
            return nil
        }
        let participants = participantHandles.map(contacts.displayName(for:))
        let groupTitle = title(row: row, participants: participants)
        let sender = sender(row: row, contacts: contacts)
        return StowerMessageItem(
            id: row.guid,
            text: body,
            timestamp: date,
            deepLink: deepLink(row: row, participantHandles: participantHandles),
            groupID: groupID(for: row.chat),
            groupTitle: groupTitle,
            isFromMe: row.isFromMe,
            sender: sender
        )
    }

    private static func cleanBody(_ body: String?) -> String? {
        guard let body else {
            return nil
        }
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func title(
        row: StowerSourceMessageRow,
        participants: [String]
    ) -> String {
        let displayName = row.chat.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        let uniqueParticipants = Array(Set(participants)).sorted()
        if !uniqueParticipants.isEmpty {
            return uniqueParticipants.joined(separator: ", ")
        }
        return row.chat.identifier
    }

    private static func sender(
        row: StowerSourceMessageRow,
        contacts: StowerContactsResolver
    ) -> String {
        guard !row.isFromMe else {
            return "Me"
        }
        guard let handle = row.senderHandle, !handle.isEmpty else {
            return "Unknown"
        }
        return contacts.displayName(for: handle)
    }

    private static func deepLink(
        row: StowerSourceMessageRow,
        participantHandles: [String]
    ) -> URL? {
        guard row.chat.style == 45, let handle = participantHandles.first else {
            return nil
        }
        return URL(string: "sms:\(handle)")
    }

    private static func groupID(for chat: StowerSourceChatRow) -> String {
        if let guid = chat.guid, !guid.isEmpty {
            return guid
        }
        if !chat.identifier.isEmpty {
            return chat.identifier
        }
        return "chat:\(chat.rowID)"
    }
}
