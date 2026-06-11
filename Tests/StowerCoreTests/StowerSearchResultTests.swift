import Foundation
import Testing

@testable import StowerCore

@Suite("StowerSearchResult")
internal struct StowerSearchResultTests {
    @Test("grouping preserves rank order within each group")
    internal func groupingPreservesRank() throws {
        let first = try result(id: "first", groupID: "shared", score: -3)
        let second = try result(id: "second", groupID: "other", score: -2)
        let third = try result(id: "third", groupID: "shared", score: -1)

        let groups = StowerSearchResult.groupedByGroupID([first, second, third])

        #expect(groups["shared"]?.map(\.item.id) == ["messages:first", "messages:third"])
        #expect(groups["other"]?.map(\.item.id) == ["messages:second"])
    }

    private func result(
        id: String,
        groupID: String,
        score: Double
    ) throws -> StowerSearchResult {
        let stored = try StowerStoredItem(
            from: GroupedTestItem(id: id, groupID: groupID)
        )
        return StowerSearchResult(item: stored, snippet: id, score: score)
    }
}

private struct GroupedTestItem: StowerIndexedItem {
    fileprivate let id: String
    fileprivate let source = StowerSource.messages
    fileprivate let text = "body"
    fileprivate let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    fileprivate let metadata: [String: String] = [:]
    fileprivate let deepLink: URL? = nil
    fileprivate let groupID: String
    fileprivate let groupTitle = "Title"
}
