import Foundation
import Testing

@testable import StowerMacUI

/// The trial-mint client returns `{licenseKey, licenseID, machineFile}` on
/// success, `.retryShortly` on the server's transient status, and `.unreachable`
/// on a transport throw — never a half-minted license — all from a stub transport.
@Suite internal struct StowerTrialMintClientTests {
    private let baseURL = "https://example.invalid/functions/v1/license"

    private func transport(status: Int, json: String) throws -> StowerTrialMintClient.Transport {
        let url = try #require(URL(string: "https://example.invalid/mint"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        let data = Data(json.utf8)
        return { _ in (data, response) }
    }

    private func client(status: Int, json: String) throws -> StowerTrialMintClient {
        StowerTrialMintClient(
            functionBaseURL: baseURL,
            transport: try transport(status: status, json: json)
        )
    }

    @Test("a 200 with licenseKey, licenseID, and machineFile mints")
    internal func mints() async throws {
        let client = try client(
            status: 200,
            json: #"{"minted":true,"licenseKey":"KEY-1","licenseID":"lic-1","#
                + #""machineID":"m-1","machineFile":"MF-1"}"#
        )
        #expect(
            await client.mint(fingerprint: "fp")
                == .minted(licenseKey: "KEY-1", licenseID: "lic-1", machineFile: "MF-1")
        )
    }

    @Test("a 503 is a transient retry, not a failure")
    internal func retriesShortly() async throws {
        let client = try client(status: 503, json: #"{"error":"retry"}"#)
        #expect(await client.mint(fingerprint: "fp") == .retryShortly)
    }

    @Test("a transport throw is unreachable")
    internal func unreachableOnThrow() async {
        let client = StowerTrialMintClient(
            functionBaseURL: baseURL,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(await client.mint(fingerprint: "fp") == .unreachable)
    }

    @Test("a 200 missing the machineFile is unreachable, never a half-minted license")
    internal func unreachableOnPartialBody() async throws {
        let client = try client(status: 200, json: #"{"licenseKey":"KEY-1","licenseID":"lic-1"}"#)
        #expect(await client.mint(fingerprint: "fp") == .unreachable)
    }

    @Test("a 200 with empty fields is unreachable")
    internal func unreachableOnEmptyFields() async throws {
        let client = try client(
            status: 200,
            json: #"{"licenseKey":"","licenseID":"","machineFile":""}"#
        )
        #expect(await client.mint(fingerprint: "fp") == .unreachable)
    }

    @Test("the request posts only the fingerprint to the mint-trial route")
    internal func requestShape() async throws {
        let captured = CapturedMintRequest()
        let client = StowerTrialMintClient(
            functionBaseURL: baseURL,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/mint"))
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (
                    Data(#"{"licenseKey":"k","licenseID":"l","machineFile":"m"}"#.utf8), response
                )
            }
        )

        _ = await client.mint(fingerprint: "fp-hash")

        let request = try #require(await captured.request)
        #expect(request.url?.absoluteString == baseURL + "/mint-trial")
        let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("fp-hash"))
    }
}

/// Captures the request a stub transport received, across the `Sendable` boundary.
private actor CapturedMintRequest {
    private(set) var request: URLRequest?

    func set(_ request: URLRequest) {
        self.request = request
    }
}
