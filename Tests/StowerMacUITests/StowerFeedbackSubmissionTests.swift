import Foundation
import Testing

@testable import StowerMacUI

/// The payload's encoding contract: the license `key` never appears
/// (I-InstanceIDNotKey), a blank email encodes as JSON `null` (I-BlankEmailNull),
/// and the keys are camelCase (matches `deno/feedback/main.ts`).
@Suite internal struct StowerFeedbackSubmissionTests {

    /// Encodes a submission to a JSON object for key/value assertions.
    private func encodedObject(_ submission: StowerFeedbackSubmission) throws -> [String: Any] {
        let data = try JSONEncoder().encode(submission)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("I-InstanceIDNotKey: a paid submission carries instanceID, never the license key")
    internal func paidSubmissionOmitsKey() throws {
        let secretKey = "80e15db5-c796-436b-850c-8f9c98a48abe"
        let submission = StowerFeedbackSubmission(
            message: "Great app",
            email: "user@example.com",
            instanceID: "inst-42",
            appVersion: "1.0 (1)",
            osVersion: "macOS 15.4",
            licenseStatus: .paid
        )
        let data = try JSONEncoder().encode(submission)
        let json = try #require(String(data: data, encoding: .utf8))
        let object = try encodedObject(submission)

        #expect(object["instanceID"] as? String == "inst-42")
        #expect(object["key"] == nil)
        #expect(object["license_key"] == nil)
        // The license key string must not appear anywhere in the encoded bytes,
        // and neither must a `key` field name.
        #expect(!json.contains(secretKey))
        #expect(!json.contains("\"key\""))
        #expect(!json.contains("license_key"))
    }

    @Test("I-BlankEmailNull: a nil email encodes as JSON null, not an empty string")
    internal func nilEmailEncodesAsNull() throws {
        let submission = StowerFeedbackSubmission(
            message: "hi",
            email: nil,
            instanceID: nil,
            appVersion: "1.0 (1)",
            osVersion: "macOS 15.4",
            licenseStatus: .trial
        )
        let object = try encodedObject(submission)
        // The key is present with a JSON null (NSNull), not "".
        #expect(object["email"] is NSNull)
        #expect(object["email"] as? String != "")
    }

    @Test("licenseStatus and instanceID encode as camelCase, matching the Deno contract")
    internal func camelCaseKeysAndRawStatus() throws {
        let submission = StowerFeedbackSubmission(
            message: "hi",
            email: nil,
            instanceID: "inst-1",
            appVersion: "1.0 (1)",
            osVersion: "macOS 15.4",
            licenseStatus: .paid
        )
        let object = try encodedObject(submission)
        #expect(object["licenseStatus"] as? String == "paid")
        #expect(object["appVersion"] as? String == "1.0 (1)")
        #expect(object["osVersion"] as? String == "macOS 15.4")
        #expect(object["instanceID"] as? String == "inst-1")
        // No snake_case leaked in.
        #expect(object["license_status"] == nil)
        #expect(object["app_version"] == nil)
    }

    @Test("a trial submission encodes instanceID as JSON null")
    internal func trialInstanceIDNull() throws {
        let submission = StowerFeedbackSubmission(
            message: "hi",
            email: nil,
            instanceID: nil,
            appVersion: "1.0 (1)",
            osVersion: "macOS 15.4",
            licenseStatus: .trial
        )
        let object = try encodedObject(submission)
        #expect(object["instanceID"] is NSNull)
        #expect(object["licenseStatus"] as? String == "trial")
    }
}
