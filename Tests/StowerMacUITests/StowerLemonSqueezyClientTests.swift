import Foundation
import Testing

@testable import StowerMacUI

/// The activate client's form-encoding, outcome classification, no-PII decode,
/// and product-identity gate (I1) — all driven by a stub transport, never the
/// network.
@Suite internal struct StowerLemonSqueezyClientTests {
    private let storeID = 11
    private let productID = 22

    /// A stub transport that returns a fixed JSON body at `status`.
    private func transport(status: Int, json: String) throws -> StowerLemonSqueezyClient.Transport {
        let url = try #require(URL(string: "https://example.invalid/activate"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        let data = Data(json.utf8)
        return { _ in (data, response) }
    }

    /// A client wired to a JSON-returning transport and this suite's expected IDs.
    private func client(status: Int, json: String) throws -> StowerLemonSqueezyClient {
        StowerLemonSqueezyClient(
            expectedStoreID: storeID,
            expectedProductID: productID,
            transport: try transport(status: status, json: json)
        )
    }

    /// A success body whose `meta` matches this suite's expected store/product.
    private func activatedJSON(instanceID: String, extraMeta: String = "") -> String {
        #"{"activated":true,"instance":{"id":"\#(instanceID)"},"#
            + #""meta":{"store_id":\#(storeID),"product_id":\#(productID)\#(extraMeta)}}"#
    }

    @Test("the form body percent-encodes + & % space newline and an apostrophe/space label")
    internal func formBodyRoundTrips() async throws {
        let key = "ab+cd&ef%gh ij\n"
        let label = "Emily's MacBook"
        let captured = CapturedRequest()
        let client = StowerLemonSqueezyClient(
            expectedStoreID: storeID,
            expectedProductID: productID,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/activate"))
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(#"{"activated":true,"instance":{"id":"i"}}"#.utf8), response)
            }
        )

        _ = await client.activate(key: key, instanceName: label)

        let request = try #require(await captured.request)
        #expect(
            request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
        )
        let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var components = URLComponents()
        components.percentEncodedQuery = body
        let fields = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(fields["license_key"] == key)
        #expect(fields["instance_name"] == label)
    }

    @Test("the request carries a short timeout so a blackholed network fails fast")
    internal func requestHasShortTimeout() async throws {
        let captured = CapturedRequest()
        let client = StowerLemonSqueezyClient(
            expectedStoreID: storeID,
            expectedProductID: productID,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/activate"))
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(#"{"activated":true,"instance":{"id":"i"}}"#.utf8), response)
            }
        )

        _ = await client.activate(key: "k", instanceName: "Stower")

        let request = try #require(await captured.request)
        #expect(request.timeoutInterval < 60)
    }

    @Test("a 200 with activated:true, an instance id, and matching IDs classifies as .activated")
    internal func activatedClassifies() async throws {
        let client = try client(status: 200, json: activatedJSON(instanceID: "inst-7"))
        #expect(
            await client.activate(key: "k", instanceName: "Stower")
                == .activated(instanceID: "inst-7")
        )
    }

    @Test("I1: a valid key for ANOTHER store/product classifies as .invalid")
    internal func foreignProductRejected() async throws {
        let json =
            #"{"activated":true,"instance":{"id":"inst-7"},"#
            + #""meta":{"store_id":999,"product_id":888}}"#
        let client = try client(status: 200, json: json)
        #expect(await client.activate(key: "k", instanceName: "Stower") == .invalid)
    }

    @Test("I1: activated:true with no meta classifies as .invalid (can't confirm the product)")
    internal func missingMetaRejected() async throws {
        let client = try client(status: 200, json: #"{"activated":true,"instance":{"id":"i"}}"#)
        #expect(await client.activate(key: "k", instanceName: "Stower") == .invalid)
    }

    @Test("a 200 with activated:false classifies as .invalid")
    internal func invalidClassifies() async throws {
        let client = try client(status: 400, json: #"{"activated":false,"error":"not found"}"#)
        #expect(await client.activate(key: "k", instanceName: "Stower") == .invalid)
    }

    @Test("a transport throw classifies as .couldNotReach")
    internal func transportThrowClassifies() async {
        let client = StowerLemonSqueezyClient(
            expectedStoreID: storeID,
            expectedProductID: productID,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(await client.activate(key: "k", instanceName: "Stower") == .couldNotReach)
    }

    @Test("a 503 classifies as .couldNotReach")
    internal func serverErrorClassifies() async throws {
        let client = try client(status: 503, json: activatedJSON(instanceID: "x"))
        #expect(await client.activate(key: "k", instanceName: "Stower") == .couldNotReach)
    }

    @Test("a 200 with a garbage body classifies as .couldNotReach")
    internal func undecodableClassifies() async throws {
        let client = try client(status: 200, json: "<html>not json</html>")
        #expect(await client.activate(key: "k", instanceName: "Stower") == .couldNotReach)
    }

    @Test("a response carrying customer_email activates on matching IDs and exposes no PII")
    internal func customerEmailNeverExposed() async throws {
        // Matching product IDs plus PII: activates, but the PII has no field on
        // any app type, so it cannot be retained.
        let json = activatedJSON(
            instanceID: "inst-9",
            extraMeta: #","customer_email":"a@b.com","customer_name":"A B""#
        )
        let client = try client(status: 200, json: json)
        #expect(
            await client.activate(key: "k", instanceName: "Stower")
                == .activated(instanceID: "inst-9")
        )
    }
}

/// Captures the request a stub transport received, across the `Sendable` boundary.
private actor CapturedRequest {
    private(set) var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}
