/// The result of applying the tokenization policy to one text.
internal enum StowerTokenPlan: Sendable, Equatable {
    /// The text was rejected before embedding, with a reason.
    case skipped(String)

    /// Input ids ready for the model, special tokens included.
    case encoded([Int])
}

/// Decides whether a text is worth embedding and shapes its input ids.
///
/// Pure and model-agnostic so it is unit-testable without Core ML: it operates
/// on subword ids the tokenizer already produced. Texts with fewer than
/// `minimumMeaningfulTokens` non-unknown subwords (emoji-only runs, ZWJ
/// sequences, CJK under an English vocab) are skipped, since they tokenize to
/// all-`[UNK]` junk vectors that would flood the semantic arm.
internal struct StowerTokenizationPolicy: Sendable {
    internal let clsTokenID: Int
    internal let sepTokenID: Int
    internal let padTokenID: Int
    internal let unknownTokenID: Int?
    internal let maxTokens: Int
    internal let minimumMeaningfulTokens: Int

    /// Plans a stored text; short or all-unknown texts are skipped.
    internal func plan(subwordIDs: [Int]) -> StowerTokenPlan {
        let meaningful = subwordIDs.filter { $0 != unknownTokenID }.count
        guard meaningful >= minimumMeaningfulTokens else {
            return .skipped("fewer than \(minimumMeaningfulTokens) meaningful tokens")
        }
        return .encoded(framed(subwordIDs))
    }

    /// Plans a query; queries are always embedded, only truncated.
    internal func encodeQuery(subwordIDs: [Int]) -> [Int] {
        framed(subwordIDs)
    }

    /// Pads a batch of sequences to the longest, returning ids and masks.
    internal func padded(_ sequences: [[Int]]) -> (ids: [[Int]], mask: [[Int]]) {
        let width = sequences.map(\.count).max() ?? 0
        var ids: [[Int]] = []
        var mask: [[Int]] = []
        for sequence in sequences {
            let padding = width - sequence.count
            ids.append(sequence + Array(repeating: padTokenID, count: padding))
            mask.append(
                Array(repeating: 1, count: sequence.count)
                    + Array(repeating: 0, count: padding)
            )
        }
        return (ids, mask)
    }

    private func framed(_ subwordIDs: [Int]) -> [Int] {
        let budget = max(0, maxTokens - 2)  // reserve room for CLS + SEP
        return [clsTokenID] + subwordIDs.prefix(budget) + [sepTokenID]
    }
}
