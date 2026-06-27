import Foundation
import Testing

@testable import StowerMacUI

/// The check-in client maps the §5 status table to typed results, signs each
/// `/check-in` with the JC5 headers, and builds the LS checkout URL carrying the
/// license id — all from a stub transport, no network.
@Suite internal struct StowerLicenseCheckInClientTests {
    private typealias Transport = StowerLicenseCheckInClient.Transport
    private let baseURL = "https://example.invalid/functions/v1/license"

    private func transport(status: Int, json: String) throws -> Transport {
        let url = try #require(URL(string: "https://example.invalid/check-in"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        let data = Data(json.utf8)
        return { _ in (data, response) }
    }

    private func client(status: Int, json: String) throws -> StowerLicenseCheckInClient {
        StowerLicenseCheckInClient(
            functionBaseURL: baseURL,
            transport: try transport(status: status, json: json)
        )
    }

    private func checkIn(_ client: StowerLicenseCheckInClient) async -> StowerCheckInResult {
        await client.checkIn(licenseID: "lic-1", fingerprint: "fp", licenseKey: "key")
    }

    @Test("200 ok with a machineFile maps to .ok")
    internal func mapsOk() async throws {
        let client = try client(status: 200, json: #"{"status":"ok","machineFile":"MF"}"#)
        #expect(await checkIn(client) == .ok(machineFile: "MF"))
    }

    @Test("200 ok missing the machineFile is .unreachable, never a false valid")
    internal func okMissingFileIsUnreachable() async throws {
        let client = try client(status: 200, json: #"{"status":"ok"}"#)
        #expect(await checkIn(client) == .unreachable)
    }

    @Test("200 expired maps to .trialExpired carrying the licenseID")
    internal func mapsExpired() async throws {
        let client = try client(status: 200, json: #"{"status":"expired","licenseID":"lic-9"}"#)
        #expect(await checkIn(client) == .trialExpired(licenseID: "lic-9"))
    }

    @Test("200 wrong_version maps to .wrongVersion carrying the licenseID")
    internal func mapsWrongVersion() async throws {
        let client = try client(
            status: 200,
            json: #"{"status":"wrong_version","licenseID":"lic-7"}"#
        )
        #expect(await checkIn(client) == .wrongVersion(licenseID: "lic-7"))
    }

    @Test("401 maps to .badSignature")
    internal func mapsBadSignature() async throws {
        let client = try client(status: 401, json: #"{"status":"bad_signature"}"#)
        #expect(await checkIn(client) == .badSignature)
    }

    @Test("404 maps to .unknownLicense")
    internal func mapsUnknownLicense() async throws {
        let client = try client(status: 404, json: #"{"status":"unknown_license"}"#)
        #expect(await checkIn(client) == .unknownLicense)
    }

    @Test("409 maps to .fingerprintMismatch")
    internal func mapsFingerprintMismatch() async throws {
        let client = try client(status: 409, json: #"{"status":"fingerprint_mismatch"}"#)
        #expect(await checkIn(client) == .fingerprintMismatch)
    }

    @Test("503 maps to .unreachable")
    internal func mapsRetryShortly() async throws {
        let client = try client(status: 503, json: #"{"status":"retry_shortly"}"#)
        #expect(await checkIn(client) == .unreachable)
    }

    @Test("a transport throw is .unreachable")
    internal func throwIsUnreachable() async {
        let client = StowerLicenseCheckInClient(
            functionBaseURL: baseURL,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(await checkIn(client) == .unreachable)
    }

    @Test("the check-in POST carries JC5 headers and signs the exact body it sends")
    internal func signsRequestWithJC5Headers() async throws {
        let captured = CapturedCheckInRequest()
        let client = StowerLicenseCheckInClient(
            functionBaseURL: baseURL,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/check-in"))
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(#"{"status":"ok","machineFile":"MF"}"#.utf8), response)
            },
            timestamp: { "1700000000" },
            nonce: { "test-nonce" }
        )

        _ = await client.checkIn(
            licenseID: "lic-1",
            fingerprint: "fp-hash",
            licenseKey: "secret-key"
        )

        let request = try #require(await captured.request)
        #expect(request.url?.absoluteString == baseURL + "/check-in")
        #expect(request.value(forHTTPHeaderField: "X-Stower-Timestamp") == "1700000000")
        #expect(request.value(forHTTPHeaderField: "X-Stower-Nonce") == "test-nonce")
        let body = try #require(request.httpBody)
        let bodyString = try #require(String(bytes: body, encoding: .utf8))
        #expect(bodyString.contains("lic-1"))
        #expect(bodyString.contains("fp-hash"))
        // The signature is over the EXACT bytes sent, with the canonical /check-in path.
        let expected = StowerCheckInSignature().sign(
            method: "POST",
            timestamp: "1700000000",
            nonce: "test-nonce",
            body: body,
            key: "secret-key"
        )
        #expect(request.value(forHTTPHeaderField: "X-Stower-Signature") == expected.signature)
    }

    @Test("checkoutURL carries the license id as Lemon Squeezy custom data")
    internal func checkoutURLCarriesLicenseID() throws {
        let url = try #require(StowerLicenseCheckInClient.checkoutURL(licenseID: "lic-123"))
        let string = url.absoluteString
        #expect(string.contains("lemonsqueezy.com"))
        // The bracket keys are percent-encoded; the LS backend decodes them.
        #expect(string.contains("checkout%5Bcustom%5D%5Blicense_id%5D=lic-123"))
    }

    @Test("checkoutURL percent-encodes a license id with reserved characters")
    internal func checkoutURLEncodesReservedCharacters() throws {
        let url = try #require(StowerLicenseCheckInClient.checkoutURL(licenseID: "a/b&c"))
        // The id is percent-encoded so it can't inject extra query pairs.
        #expect(url.absoluteString.contains("license_id%5D=a%2Fb%26c"))
    }
}

/// Captures the request a stub transport received, across the `Sendable` boundary.
private actor CapturedCheckInRequest {
    private(set) var request: URLRequest?

    func set(_ request: URLRequest) {
        self.request = request
    }
}
