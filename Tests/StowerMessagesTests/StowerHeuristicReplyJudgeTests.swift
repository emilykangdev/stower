import Foundation
import Testing

@testable import StowerMessages

@Suite("StowerHeuristicReplyJudge")
internal struct StowerHeuristicReplyJudgeTests {
    private let judge = StowerHeuristicReplyJudge()

    @Test("a cue plus a question mark is the strongest signal")
    internal func cueAndQuestion() async {
        let verdict = await judge.judge(messageText: "can you send that file?", context: [])
        #expect(verdict.expectsReply)
        #expect(verdict.replyExpectationConfidence == 1.0)
        #expect(verdict.verdictSource == .heuristic)
    }

    @Test("an ask-cue with no question mark still expects a reply, graded lower")
    internal func cueOnly() async {
        let verdict = await judge.judge(
            messageText: "wondering if you're free saturday",
            context: []
        )
        #expect(verdict.expectsReply)
        #expect(verdict.replyExpectationConfidence == 0.6)
    }

    @Test("a bare question mark is the weakest positive signal")
    internal func bareQuestion() async {
        let verdict = await judge.judge(messageText: "what?", context: [])
        #expect(verdict.expectsReply)
        #expect(verdict.replyExpectationConfidence == 0.4)
    }

    @Test("a plain statement expects no reply")
    internal func statement() async {
        let verdict = await judge.judge(messageText: "sounds good", context: [])
        #expect(!verdict.expectsReply)
        #expect(verdict.replyExpectationConfidence == 0.0)
    }

    @Test("a nil-text (non-text) act never expects a reply")
    internal func nilTextNeverExpects() async {
        let verdict = await judge.judge(messageText: nil, context: [])
        #expect(!verdict.expectsReply)
        #expect(verdict.replyExpectationConfidence == 0.0)
    }

    @Test("judgeVersion changes when the prompt template changes (M12)")
    internal func judgeVersionDerivedFromPrompt() {
        let sameA = StowerSpyReplyJudge(judgeVersion: stowerShortHash("prompt-A|model-X"))
        let sameB = StowerSpyReplyJudge(judgeVersion: stowerShortHash("prompt-A|model-X"))
        let different = StowerSpyReplyJudge(judgeVersion: stowerShortHash("prompt-B|model-X"))
        #expect(sameA.judgeVersion == sameB.judgeVersion)
        #expect(sameA.judgeVersion != different.judgeVersion)
        // The real heuristic derives a stable, non-empty version too.
        #expect(!judge.judgeVersion.isEmpty)
    }
}
