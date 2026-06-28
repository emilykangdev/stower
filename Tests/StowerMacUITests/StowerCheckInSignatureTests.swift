import Foundation
import Testing

@testable import StowerMacUI

/// B-I3 (I16/JC5): the Swift signer reproduces the committed parity vector
/// byte-for-byte, so the Edge Function's `requestSignature.ts` verifier accepts
/// every reachable check-in.
///
/// Reads the committed fixture, never a hardcoded copy — a drift in either side
/// fails this test.
@Suite internal struct StowerCheckInSignatureTests {
    /// The committed JC5 parity vector, decoded from the Edge Function fixture.
    private struct Vector: Decodable {
        let key: String
        let method: String
        let path: String
        let timestamp: String
        let nonce: String
        let body: String
        let signature: String
    }

    /// Loads `supabase/functions/license/fixtures/jc5-signature-vector.json` from
    /// the repo, located relative to this source file (tests run from the package
    /// root, but the path is derived from `#filePath` so it is CWD-independent).
    private func loadVector() throws -> Vector {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // StowerMacUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("supabase/functions/license/fixtures/jc5-signature-vector.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(Vector.self, from: data)
    }

    @Test("the signer reproduces the committed JC5 parity vector's signature")
    internal func reproducesCommittedVector() throws {
        let vector = try loadVector()
        let headers = StowerCheckInSignature().sign(
            method: vector.method,
            path: vector.path,
            timestamp: vector.timestamp,
            nonce: vector.nonce,
            body: Data(vector.body.utf8),
            key: vector.key
        )
        #expect(headers.signature == vector.signature)
        #expect(headers.timestamp == vector.timestamp)
        #expect(headers.nonce == vector.nonce)
    }

    @Test("the default signing path is the canonical /check-in constant")
    internal func defaultPathIsCanonical() {
        #expect(StowerCheckInSignature.signingPath == "/check-in")
        let withDefault = StowerCheckInSignature().sign(
            method: "POST",
            timestamp: "1700000000",
            nonce: "n",
            body: Data("{}".utf8),
            key: "k"
        )
        let withExplicit = StowerCheckInSignature().sign(
            method: "POST",
            path: "/check-in",
            timestamp: "1700000000",
            nonce: "n",
            body: Data("{}".utf8),
            key: "k"
        )
        #expect(withDefault.signature == withExplicit.signature)
    }
}
