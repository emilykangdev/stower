import Foundation
import Testing

@testable import StowerCore

@Suite("StowerGroupedResult")
internal struct StowerGroupedResultTests {
    @Test("collapses ranked items to conversations, best group first")
    internal func collapsesToConversations() throws {
        var hits: [StowerRetrievedItem] = []
        hits.append(try retrieved(id: "a", title: "Book Club", group: "convo-1", rank: 0))
        hits.append(try retrieved(id: "b", title: "Book Club", group: "convo-1", rank: 1))
        hits.append(try retrieved(id: "c", title: "Mom", group: "convo-2", rank: 2))

        let groups = hits.stowerGroupedByConversation()

        #expect(groups.map(\.groupID) == ["convo-1", "convo-2"])
        #expect(groups.map(\.groupTitle) == ["Book Club", "Mom"])
        #expect(groups.map(\.matchCount) == [2, 1])
        #expect(groups.map(\.best.item.id) == ["messages:a", "messages:c"])
    }

    @Test("a group takes the slot of its highest-ranked item")
    internal func groupOrderFollowsBestRank() throws {
        // Interleaved: convo-1 first appears at rank 0, convo-2 at rank 1.
        var hits: [StowerRetrievedItem] = []
        hits.append(try retrieved(id: "a", title: "Book Club", group: "convo-1", rank: 0))
        hits.append(try retrieved(id: "c", title: "Mom", group: "convo-2", rank: 1))
        hits.append(try retrieved(id: "b", title: "Book Club", group: "convo-1", rank: 2))

        let groups = hits.stowerGroupedByConversation()

        #expect(groups.map(\.groupID) == ["convo-1", "convo-2"])
        #expect(groups.first?.matchCount == 2)
        #expect(groups.first?.best.item.id == "messages:a")
    }

    @Test("an empty ranking yields no groups")
    internal func emptyRankingYieldsNoGroups() {
        #expect([StowerRetrievedItem]().stowerGroupedByConversation().isEmpty)
    }

    private func retrieved(
        id: String,
        title: String,
        group: String,
        rank: Int
    ) throws -> StowerRetrievedItem {
        let stored = try StowerStoredItem(
            from: StowerTestItem(id: id, text: "body \(id)", title: title, groupID: group)
        )
        return StowerRetrievedItem(
            item: stored,
            snippet: nil,
            ftsRank: rank,
            semanticRank: nil,
            fusedScore: 1.0 / Double(rank + 1)
        )
    }
}
