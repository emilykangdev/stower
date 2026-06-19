import Foundation
import Testing

@testable import StowerMacUI

/// The Keygen client decodes activate / check-out / validate-key and classifies
/// reachable-vs-verdict, while surfacing a transport throw (not swallowing it) —
/// all driven by a stub transport, never the network.
@Suite internal struct StowerKeygenClientTests {
    private let account = "acct-1"

    /// A stub transport returning a fixed JSON body at `status`.
    private func transport(status: Int, json: String) throws -> StowerKeygenClient.Transport {
        let url = try #require(URL(string: "https://example.invalid/keygen"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        let data = Data(json.utf8)
        return { _ in (data, response) }
    }

    private func client(status: Int, json: String) throws -> StowerKeygenClient {
        StowerKeygenClient(account: account, transport: try transport(status: status, json: json))
    }

    @Test("activate decodes the machine id on success")
    internal func activateDecodesMachineID() async throws {
        let client = try client(status: 201, json: #"{"data":{"id":"machine-1"}}"#)
        let result = try await client.activate(
            licenseKey: "k",
            licenseID: "lic-1",
            fingerprint: "fp"
        )
        #expect(result == .activated(machineID: "machine-1"))
    }

    @Test("activate classifies a 422 as the machine limit being reached")
    internal func activateClassifiesLimit() async throws {
        let client = try client(
            status: 422,
            json: #"{"errors":[{"code":"MACHINE_LIMIT_EXCEEDED"}]}"#
        )
        let result = try await client.activate(
            licenseKey: "k",
            licenseID: "lic-1",
            fingerprint: "fp"
        )
        #expect(result == .limitReached)
    }

    @Test("activate surfaces a 422 that is NOT the machine limit, rather than masking it")
    internal func activateSurfacesNonLimit422() async throws {
        let client = try client(status: 422, json: #"{"errors":[{"code":"FINGERPRINT_TAKEN"}]}"#)
        await #expect(throws: StowerKeygenError.server(status: 422)) {
            _ = try await client.activate(licenseKey: "k", licenseID: "l", fingerprint: "fp")
        }
    }

    @Test("activate surfaces a transport throw rather than swallowing it")
    internal func activateSurfacesTransportThrow() async {
        let client = StowerKeygenClient(
            account: account,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        await #expect(throws: URLError.self) {
            _ = try await client.activate(licenseKey: "k", licenseID: "l", fingerprint: "fp")
        }
    }

    @Test("activate throws a server error on a 5xx")
    internal func activateThrowsOnServerError() async throws {
        let client = try client(status: 503, json: "{}")
        await #expect(throws: StowerKeygenError.server(status: 503)) {
            _ = try await client.activate(licenseKey: "k", licenseID: "l", fingerprint: "fp")
        }
    }

    @Test("activate sends the License Authorization header and the fingerprint")
    internal func activateRequestShape() async throws {
        let captured = CapturedKeygenRequest()
        let client = StowerKeygenClient(
            account: account,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/keygen"))
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)
                )
                return (Data(#"{"data":{"id":"m"}}"#.utf8), response)
            }
        )

        _ = try await client.activate(
            licenseKey: "secret-key",
            licenseID: "lic-1",
            fingerprint: "fp-hash"
        )

        let request = try #require(await captured.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "License secret-key")
        let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("fp-hash"))
        #expect(body.contains("lic-1"))
    }

    @Test("check-out returns the machine-file and carries the ttl query")
    internal func checkOutReturnsMachineFile() async throws {
        let certificate = "-----BEGIN MACHINE FILE-----\nQUJD\n-----END MACHINE FILE-----"
        let captured = CapturedKeygenRequest()
        let escaped = certificate.replacingOccurrences(of: "\n", with: "\\n")
        let client = StowerKeygenClient(
            account: account,
            transport: { request in
                await captured.set(request)
                let url = try #require(URL(string: "https://example.invalid/keygen"))
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                let json = #"{"data":{"attributes":{"certificate":"\#(escaped)"}}}"#
                return (Data(json.utf8), response)
            }
        )

        let file = try await client.checkOutMachineFile(machineID: "machine-1", licenseKey: "k")

        #expect(file == certificate)
        let query = try #require(await captured.request?.url?.query)
        #expect(query.contains("ttl=604800"))
    }

    @Test("check-out surfaces a transport throw")
    internal func checkOutSurfacesTransportThrow() async {
        let client = StowerKeygenClient(
            account: account,
            transport: { _ in throw URLError(.timedOut) }
        )
        await #expect(throws: URLError.self) {
            _ = try await client.checkOutMachineFile(machineID: "m", licenseKey: "k")
        }
    }

    @Test("validate-key decodes a valid verdict")
    internal func validateDecodesValid() async throws {
        let client = try client(status: 200, json: #"{"meta":{"valid":true,"code":"VALID"}}"#)
        let result = try await client.validate(licenseKey: "k", fingerprint: "fp")
        #expect(result == .valid)
    }

    @Test("validate-key decodes an invalid verdict and its code")
    internal func validateDecodesInvalid() async throws {
        let client = try client(status: 200, json: #"{"meta":{"valid":false,"code":"NO_MACHINE"}}"#)
        let result = try await client.validate(licenseKey: "k", fingerprint: "fp")
        #expect(result == .invalid(code: "NO_MACHINE"))
    }

    @Test("validate-key surfaces a transport throw")
    internal func validateSurfacesTransportThrow() async {
        let client = StowerKeygenClient(
            account: account,
            transport: { _ in throw URLError(.cannotConnectToHost) }
        )
        await #expect(throws: URLError.self) {
            _ = try await client.validate(licenseKey: "k", fingerprint: "fp")
        }
    }
}

/// Captures the request a stub transport received, across the `Sendable` boundary.
private actor CapturedKeygenRequest {
    private(set) var request: URLRequest?

    func set(_ request: URLRequest) {
        self.request = request
    }
}
