import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerReplyVerdictCache")
internal struct StowerReplyVerdictCacheTests {
    @Test("a verdict round-trips on a matching version, guid, and input hash")
    internal func roundTrip() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let verdict = StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.8,
            verdictSource: .languageModel
        )
        try await cache.upsert(judgeVersion: "v1", guid: "g1", inputHash: "h1", verdict: verdict)

        let fetched = try await cache.existing(judgeVersion: "v1", guid: "g1", inputHash: "h1")
        #expect(fetched?.expectsReply == true)
        #expect(fetched?.replyExpectationConfidence == 0.8)
        #expect(fetched?.verdictSource == .languageModel)
    }

    @Test("a different judge version or input hash misses, forcing a re-judge")
    internal func keyMiss() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let verdict = StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.8,
            verdictSource: .languageModel
        )
        try await cache.upsert(judgeVersion: "v1", guid: "g1", inputHash: "h1", verdict: verdict)

        #expect(try await cache.existing(judgeVersion: "v2", guid: "g1", inputHash: "h1") == nil)
        #expect(try await cache.existing(judgeVersion: "v1", guid: "g1", inputHash: "h2") == nil)
        #expect(try await cache.existing(judgeVersion: "v1", guid: "gX", inputHash: "h1") == nil)
    }

    @Test("upsert is idempotent: re-writing one key updates in place, not duplicates")
    internal func idempotentUpsert() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let first = StowerReplyExpectation(
            expectsReply: false,
            replyExpectationConfidence: 0.2,
            verdictSource: .languageModel
        )
        let second = StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.95,
            verdictSource: .languageModel
        )
        try await cache.upsert(judgeVersion: "v1", guid: "g1", inputHash: "h1", verdict: first)
        try await cache.upsert(judgeVersion: "v1", guid: "g1", inputHash: "h2", verdict: second)

        #expect(try await cache.existing(judgeVersion: "v1", guid: "g1", inputHash: "h1") == nil)
        let latest = try await cache.existing(judgeVersion: "v1", guid: "g1", inputHash: "h2")
        #expect(latest?.expectsReply == true)
        #expect(latest?.replyExpectationConfidence == 0.95)
    }

    @Test("prune drops rows whose guid is gone or whose version is retired (M15)")
    internal func pruneByGuidAndVersion() async throws {
        let cache = try StowerReplyVerdictCache.inMemory()
        let verdict = StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.7,
            verdictSource: .languageModel
        )
        try await cache.upsert(judgeVersion: "v1", guid: "keep", inputHash: "h", verdict: verdict)
        try await cache.upsert(judgeVersion: "v1", guid: "gone", inputHash: "h", verdict: verdict)
        try await cache.upsert(judgeVersion: "old", guid: "keep", inputHash: "h", verdict: verdict)

        try await cache.prune(keepingGUIDs: ["keep"], keepingVersions: ["v1"])

        #expect(try await cache.existing(judgeVersion: "v1", guid: "keep", inputHash: "h") != nil)
        #expect(try await cache.existing(judgeVersion: "v1", guid: "gone", inputHash: "h") == nil)
        #expect(try await cache.existing(judgeVersion: "old", guid: "keep", inputHash: "h") == nil)
    }

    @Test("opening a cache over a non-database file throws, so the provider can fall back")
    internal func corruptFileOpenThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-verdict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(StowerReplyVerdictCache.fileName)
        try Data("this is not a sqlite database".utf8).write(to: path)

        // The provider wraps this open in `try?`, so a throw here degrades the
        // board to heuristic rather than blocking it (M9, disposable cache).
        #expect(throws: (any Error).self) {
            _ = try StowerReplyVerdictCache(path: path.path)
        }
    }

    @Test("a schema-version bump drops the disposable cache rather than failing")
    internal func versionBumpErases() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stower-verdict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(StowerReplyVerdictCache.fileName).path
        let verdict = StowerReplyExpectation(
            expectsReply: true,
            replyExpectationConfidence: 0.6,
            verdictSource: .languageModel
        )

        let original = try StowerReplyVerdictCache(path: path, schemaVersion: 1)
        try await original.upsert(judgeVersion: "v1", guid: "g1", inputHash: "h1", verdict: verdict)

        let bumped = try StowerReplyVerdictCache(path: path, schemaVersion: 2)
        #expect(try await bumped.existing(judgeVersion: "v1", guid: "g1", inputHash: "h1") == nil)
    }
}
