import Foundation
import Testing

@testable import StowerCore

@Suite("StowerIndex")
internal struct StowerIndexTests {
    @Test("round trips fields and finds body, stemmed, unicode, and title terms")
    internal func roundTripSearch() async throws {
        let index = try StowerIndex()
        var items: [TestItem] = []
        items.append(
            TestItem(
                id: "one",
                text: "Meetings at the café 🎉",
                title: "José",
                metadata: ["direction": "incoming"]
            )
        )
        items.append(TestItem(id: "two", text: "A different topic", title: "Taylor"))

        try await index.ingest(items)

        let stemmed = try await index.search("meeting")
        let folded = try await index.search("cafe")
        let title = try await index.search("Jose")

        #expect(stemmed.map(\.item.id) == ["messages:one"])
        #expect(folded.map(\.item.id) == ["messages:one"])
        #expect(title.map(\.item.id) == ["messages:one"])
        #expect(stemmed.first?.item.metadata == #"{"direction":"incoming"}"#)
        #expect(stemmed.first?.snippet.contains("<mark>") == true)
    }

    @Test("denser matches rank first")
    internal func ranksDenseMatchesFirst() async throws {
        let index = try StowerIndex()
        let dense = TestItem(id: "dense", text: "pizza pizza pizza tonight", title: "Mom")
        let sparse = TestItem(id: "sparse", text: "pizza tonight", title: "Mom")
        try await index.ingest([dense, sparse])

        let results = try await index.search("pizza")

        #expect(results.map(\.item.id) == ["messages:dense", "messages:sparse"])
    }

    @Test("body and lower-weighted title terms rank the intended thread first")
    internal func ranksBodyAndTitleTogether() async throws {
        let index = try StowerIndex()
        var items: [TestItem] = []
        items.append(TestItem(id: "mom-pizza", text: "pizza after work", title: "Mom"))
        items.append(TestItem(id: "random-pizza", text: "pizza with friends", title: "Alex"))
        items.append(TestItem(id: "random-mom", text: "Mom sent a photo", title: "Alex"))
        try await index.ingest(items)

        let results = try await index.search("Mom pizza")

        #expect(results.first?.item.id == "messages:mom-pizza")
    }

    @Test("special and empty queries do not throw")
    internal func safeQueries() async throws {
        let index = try StowerIndex()
        try await index.ingest([TestItem(id: "one", text: "ordinary text", title: "Alex")])

        for query in ["", "\"unterminated", "a AND ( NEAR:", "*"] {
            _ = try await index.search(query)
        }
    }

    @Test("a rebuild removes stale terms and preserves FTS integrity")
    internal func rebuildSupersedesContent() async throws {
        let index = try StowerIndex()
        try await index.ingest([TestItem(id: "one", text: "obsolete", title: "Alex")])
        try await index.ingest([TestItem(id: "one", text: "current", title: "Alex")])

        #expect(try await index.search("obsolete").isEmpty)
        #expect(try await index.search("current").map(\.item.id) == ["messages:one"])
    }

    @Test("source namespacing prevents native identifier collisions")
    internal func sourceNamespacing() throws {
        let message = try StowerStoredItem(
            from: TestItem(id: "shared", text: "message", title: "Messages")
        )
        let photo = try StowerStoredItem(
            from: TestItem(
                id: "shared",
                source: .photos,
                text: "photo",
                title: "Photos"
            )
        )

        #expect(message.id == "messages:shared")
        #expect(photo.id == "photos:shared")
    }

    @Test(
        "indexes one thousand synthetic items",
        .timeLimit(.minutes(1))
    )
    internal func thousandItemBatch() async throws {
        let index = try StowerIndex()
        let items = (0..<1_000).map { offset in
            TestItem(
                id: String(offset),
                text: "synthetic searchable item \(offset)",
                title: "Fixture"
            )
        }

        try await index.ingest(items)
        let results = try await index.search("searchable", limit: 10)

        #expect(results.count == 10)
    }
}

private struct TestItem: StowerIndexedItem {
    fileprivate let id: String
    fileprivate let source: StowerSource
    fileprivate let text: String
    fileprivate let timestamp: Date
    fileprivate let metadata: [String: String]
    fileprivate let deepLink: URL?
    fileprivate let groupID: String
    fileprivate let groupTitle: String

    fileprivate init(
        id: String,
        source: StowerSource = .messages,
        text: String,
        title: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.text = text
        timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        self.metadata = metadata
        deepLink = nil
        groupID = "group-\(id)"
        groupTitle = title
    }
}
