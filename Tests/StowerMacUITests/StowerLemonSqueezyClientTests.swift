import Foundation
import Testing

@testable import StowerMacUI

/// The activate client's form-encoding (I9), outcome classification (I10), and
/// no-PII decode (I12) — all driven by a stub transport, never the network.
@Suite internal struct StowerLemonSqueezyClientTests {
    /// A stub transport that returns a fixed JSON body at `status`.
    private func transport(status: Int, json: String) throws -> StowerLemonSqueezyClient.Transport {
        let url = try #require(URL(string: "https://example.invalid/activate"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        let data = Data(json.utf8)
        return { _ in (data, response) }
    }

    @Test("the form body percent-encodes + & % space newline and an apostrophe/space label")
    internal func formBodyRoundTrips() async throws {
        let key = "ab+cd&ef%gh ij\n"
        let label = "Emily's MacBook"
        let captured = CapturedRequest()
        let client = StowerLemonSqueezyClient(transport: { request in
            await captured.set(request)
            let url = try #require(URL(string: "https://example.invalid/activate"))
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (Data(#"{"activated":true,"instance":{"id":"i"}}"#.utf8), response)
        })

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

    @Test("a 200 with activated:true and an instance id classifies as .activated")
    internal func activatedClassifies() async throws {
        let client = StowerLemonSqueezyClient(
            transport: try transport(
                status: 200,
                json: #"{"activated":true,"instance":{"id":"inst-7"}}"#
            )
        )
        #expect(
            await client.activate(key: "k", instanceName: "Stower")
                == .activated(instanceID: "inst-7")
        )
    }

    @Test("a 200 with activated:false classifies as .invalid")
    internal func invalidClassifies() async throws {
        let client = StowerLemonSqueezyClient(
            transport: try transport(status: 400, json: #"{"activated":false,"error":"not found"}"#)
        )
        #expect(await client.activate(key: "k", instanceName: "Stower") == .invalid)
    }

    @Test("a transport throw classifies as .couldNotReach")
    internal func transportThrowClassifies() async {
        let client = StowerLemonSqueezyClient(transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        #expect(await client.activate(key: "k", instanceName: "Stower") == .couldNotReach)
    }

    @Test("a 503 classifies as .couldNotReach")
    internal func serverErrorClassifies() async throws {
        let client = StowerLemonSqueezyClient(
            transport: try transport(
                status: 503,
                json: #"{"activated":true,"instance":{"id":"x"}}"#
            )
        )
        #expect(await client.activate(key: "k", instanceName: "Stower") == .couldNotReach)
    }

    @Test("a 200 with a garbage body classifies as .couldNotReach")
    internal func undecodableClassifies() async throws {
        let client = StowerLemonSqueezyClient(
            transport: try transport(status: 200, json: "<html>not json</html>")
        )
        #expect(await client.activate(key: "k", instanceName: "Stower") == .couldNotReach)
    }

    @Test("a response carrying customer_email decodes the verdict and exposes no PII")
    internal func customerEmailNeverExposed() async throws {
        let json =
            #"{"activated":true,"instance":{"id":"inst-9"},"#
            + #""meta":{"customer_email":"a@b.com","customer_name":"A B"}}"#
        let client = StowerLemonSqueezyClient(transport: try transport(status: 200, json: json))
        // The outcome carries only the instance id; the response's PII has no
        // field on any app type, so it cannot be retained.
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
