import Testing
import Tokenizers

@testable import StowerCore

/// Exercises the post-tokenization skip and truncation policy through a real
/// swift-transformers `BertTokenizer` built from a tiny in-test vocab — no model
/// artifact, no network, fully deterministic.
@Suite("StowerTokenizationPolicy")
internal struct StowerTokenizerTests {
    @Test("two known words encode with CLS/SEP framing")
    internal func twoWordsEncode() {
        #expect(plan("hello world") == .encoded([2, 4, 5, 3]))
    }

    @Test("a single meaningful token is skipped")
    internal func singleTokenSkipped() {
        guard case .skipped = plan("hello") else {
            Issue.record("expected a single token to be skipped")
            return
        }
    }

    @Test("emoji-only text is skipped rather than embedded as UNK junk")
    internal func emojiSkipped() {
        guard case .skipped = plan("🎉🎉🎉") else {
            Issue.record("expected emoji-only text to be skipped")
            return
        }
    }

    @Test("a ZWJ emoji run is skipped")
    internal func zwjRunSkipped() {
        guard case .skipped = plan("👩‍👩‍👧") else {
            Issue.record("expected a ZWJ run to be skipped")
            return
        }
    }

    @Test("CJK under an English vocab is skipped (acceptable: skipped or tokenized)")
    internal func cjkHandled() {
        let outcome = plan("你好世界")
        if case .encoded = outcome { return }
        if case .skipped = outcome { return }
        Issue.record("expected CJK to be skipped or encoded, not crash")
    }

    @Test("text longer than the model limit truncates to max tokens")
    internal func longTextTruncates() {
        let longText = Array(repeating: "hello", count: 600).joined(separator: " ")
        guard case .encoded(let ids) = plan(longText) else {
            Issue.record("expected long text to encode")
            return
        }
        #expect(ids.count == 512)
        #expect(ids.first == 2)
        #expect(ids.last == 3)
    }

    // MARK: - Fixtures

    private var tokenizer: BertTokenizer {
        var vocab: [String: Int] = [:]
        vocab["[PAD]"] = 0
        vocab["[UNK]"] = 1
        vocab["[CLS]"] = 2
        vocab["[SEP]"] = 3
        vocab["hello"] = 4
        vocab["world"] = 5
        vocab["pizza"] = 6
        vocab["tonight"] = 7
        return BertTokenizer(
            vocab: vocab,
            merges: nil,
            tokenizeChineseChars: true,
            fuseUnknownTokens: false,
            doLowerCase: true
        )
    }

    private var policy: StowerTokenizationPolicy {
        StowerTokenizationPolicy(
            clsTokenID: 2,
            sepTokenID: 3,
            padTokenID: 0,
            unknownTokenID: 1,
            maxTokens: 512,
            minimumMeaningfulTokens: 2
        )
    }

    private func plan(_ text: String) -> StowerTokenPlan {
        let fallback = tokenizer.unknownTokenId ?? 0
        let ids = tokenizer.tokenize(text: text).map { tokenizer.convertTokenToId($0) ?? fallback }
        return policy.plan(subwordIDs: ids)
    }
}
