import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The data source's `mutedSenders()` query (C1): name resolution, alphabetical sort,
/// the "Dismissed" pill cross-reference, and the readable-handle fallback.
@Suite internal struct StowerMutedSendersDataSourceTests {
    private static let anchorTime = Date(timeIntervalSince1970: 1_000_000)

    @Test("mutedSenders resolves names, sorts alphabetically, and flags the dismissed (C1)")
    internal func mutedSendersResolvedSortedAndFlagged() async throws {
        let zoeHandle = "+14155550100"
        let amyHandle = "amy@example.com"
        let zoeKey = StowerDraftKey.derive(forHandle: zoeHandle)
        let amyKey = StowerDraftKey.derive(forHandle: amyHandle)
        let triage = StowerInMemoryTriageStore(
            dismissed: [
                // Zoe is ALSO actively dismissed → her row gets the pill.
                zoeKey: StowerDismissedAnchor(messageGUID: "g1", anchorTimestamp: Self.anchorTime)
            ],
            muted: [zoeKey, amyKey]
        )
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(),
            triage: triage,
            makeContactsResolver: {
                StowerContactsResolver(mapping: [zoeHandle: "Zoe", amyHandle: "Amy"])
            }
        )

        let senders = await adapter.mutedSenders()

        // Sorted by resolved name: Amy before Zoe.
        #expect(senders.map(\.displayName) == ["Amy", "Zoe"])
        #expect(senders.map(\.hasResolvedName) == [true, true])
        // Only Zoe is also dismissed.
        #expect(senders.first { $0.key == amyKey }?.isActivelyDismissed == false)
        #expect(senders.first { $0.key == zoeKey }?.isActivelyDismissed == true)
    }

    @Test("mutedSenders falls back to a readable handle when Contacts has no name (C1)")
    internal func mutedSendersFallsBackToHandle() async throws {
        let handle = "+14155559999"
        let key = StowerDraftKey.derive(forHandle: handle)
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(),
            triage: StowerInMemoryTriageStore(muted: [key]),
            makeContactsResolver: { StowerContactsResolver() }
        )

        let senders = await adapter.mutedSenders()

        #expect(senders.count == 1)
        #expect(senders.first?.displayName == handle)  // "e164:…" → "+14155559999"
        #expect(senders.first?.hasResolvedName == false)
    }

    @Test("mutedSenders resolves a contact that matches only by last-ten-digit suffix (C1)")
    internal func mutedSendersResolvesViaSuffix() async throws {
        // Muted handle is full E.164; the Contacts card stores the number WITHOUT the
        // country code, so it matches only by suffix — exactly the board's behavior.
        let mutedHandle = "+14155550100"
        let key = StowerDraftKey.derive(forHandle: mutedHandle)
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(),
            triage: StowerInMemoryTriageStore(muted: [key]),
            makeContactsResolver: {
                StowerContactsResolver(mapping: ["415-555-0100": "Suffix Match"])
            }
        )

        let senders = await adapter.mutedSenders()

        #expect(senders.first?.displayName == "Suffix Match")
        #expect(senders.first?.hasResolvedName == true)
    }

    @Test("mutedSenders is empty when nothing is muted (the toolbar control hides)")
    internal func mutedSendersEmptyWhenNoneMuted() async throws {
        let adapter = StowerLiveBoardDataSource(
            engine: StowerFakeMessagesEngine(),
            triage: StowerInMemoryTriageStore(),
            makeContactsResolver: { StowerContactsResolver() }
        )
        #expect(await adapter.mutedSenders().isEmpty)
    }
}
