import Foundation
import Testing

@testable import StowerMessages

@Suite("stowerJudgeVersion")
internal struct StowerReplyExpectationJudgeTests {
    @Test("the same instructions and model identity yield the same version")
    internal func deterministic() {
        let first = stowerJudgeVersion(instructions: "prompt-A", modelIdentity: "model-X")
        let second = stowerJudgeVersion(instructions: "prompt-A", modelIdentity: "model-X")
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("a changed prompt changes the version, so an edited judge re-judges")
    internal func differsOnInstructions() {
        let original = stowerJudgeVersion(instructions: "prompt-A", modelIdentity: "model-X")
        let edited = stowerJudgeVersion(instructions: "prompt-B", modelIdentity: "model-X")
        #expect(original != edited)
    }

    @Test("a bumped model identity changes the version, invalidating stale verdicts")
    internal func differsOnModelIdentity() {
        let epochOne = stowerJudgeVersion(instructions: "prompt-A", modelIdentity: "model-X")
        let epochTwo = stowerJudgeVersion(instructions: "prompt-A", modelIdentity: "model-Y")
        #expect(epochOne != epochTwo)
    }
}
