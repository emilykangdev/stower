import Foundation

internal enum StowerMessageMapper {
    /// The balloon bundle used by iMessage link previews; their body text is
    /// the shared URL, so they stay indexable unlike other balloon payloads.
    internal static let urlPreviewBalloonBundleID = "com.apple.messages.URLBalloonProvider"

    internal static func map(
        row: StowerSourceMessageRow,
        body: String?,
        participantHandles: [String],
        contacts: StowerContactsResolver
    ) -> StowerMessageItem? {
        guard row.associatedMessageType == 0, row.itemType == 0,
            row.balloonBundleID == nil || row.balloonBundleID == urlPreviewBalloonBundleID,
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
            deepLink: row.chat.deepLink,
            groupID: row.chat.groupID,
            groupTitle: groupTitle,
            isFromMe: row.isFromMe,
            sender: sender,
            isOneToOne: row.chat.isOneToOne
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
}
