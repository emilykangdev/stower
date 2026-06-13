import Accelerate

/// A once-per-process flat copy of every cached vector for one model.
///
/// Holds all vectors in a single contiguous buffer so the semantic arm is one
/// matrix·vector multiply, not a per-query table load (seconds at 500k rows).
internal struct StowerVectorCache: Sendable {
    internal let ids: [String]
    internal let flat: ContiguousArray<Float>
    internal let dims: Int

    internal var isEmpty: Bool { ids.isEmpty }

    internal init(vectors: [StowerCachedVector]) {
        dims = vectors.first?.vector.count ?? 0
        var ids: [String] = []
        var flat = ContiguousArray<Float>()
        ids.reserveCapacity(vectors.count)
        flat.reserveCapacity(vectors.count * dims)
        for vector in vectors where vector.vector.count == dims && dims > 0 {
            ids.append(vector.itemID)
            flat.append(contentsOf: vector.vector)
        }
        self.ids = ids
        self.flat = flat
    }

    /// Returns the `count` highest-cosine ids, best first.
    ///
    /// Vectors are stored L2-normalized, so the dot product is cosine
    /// similarity. Ties break on item id for a stable order across runs.
    internal func topK(query: [Float], count: Int) -> [(itemID: String, rank: Int)] {
        guard !isEmpty, dims > 0, query.count == dims, count > 0 else { return [] }
        guard let normalizedQuery = Self.normalized(query) else { return [] }
        let scores = scoreAll(against: normalizedQuery)
        let order = ids.indices.sorted { lhs, rhs in
            if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
            return ids[lhs] < ids[rhs]
        }
        return order.prefix(count).enumerated().map { rank, index in (ids[index], rank) }
    }

    private func scoreAll(against query: [Float]) -> [Float] {
        let rowCount = ids.count
        var scores = [Float](repeating: 0, count: rowCount)
        flat.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { vector in
                scores.withUnsafeMutableBufferPointer { output in
                    guard let matrixBase = matrix.baseAddress,
                        let vectorBase = vector.baseAddress,
                        let outputBase = output.baseAddress
                    else { return }
                    vDSP_mmul(
                        matrixBase,
                        1,
                        vectorBase,
                        1,
                        outputBase,
                        1,
                        vDSP_Length(rowCount),
                        1,
                        vDSP_Length(dims)
                    )
                }
            }
        }
        return scores
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = sqrt(vector.reduce(into: Float(0)) { $0 += $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
}
