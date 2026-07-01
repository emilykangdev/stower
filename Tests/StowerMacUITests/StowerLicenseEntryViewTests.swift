import Testing

@testable import StowerMacUI

/// The key-entry view's paste-forgiveness normalization: trims whitespace/
/// newlines, then strips an obvious `key:`/URL prefix, so a valid key with
/// copy-paste junk isn't falsely rejected.
@Suite internal struct StowerLicenseEntryViewTests {
    @Test("a clean key is unchanged")
    internal func cleanKeyUnchanged() {
        #expect(StowerLicenseEntryView.normalize("ABCD-1234") == "ABCD-1234")
    }

    @Test("leading/trailing whitespace and newlines are trimmed")
    internal func whitespaceTrimmed() {
        #expect(StowerLicenseEntryView.normalize("  ABCD-1234\n") == "ABCD-1234")
    }

    @Test("a 'key:' label prefix is stripped")
    internal func keyLabelPrefixStripped() {
        #expect(StowerLicenseEntryView.normalize("key: ABCD-1234") == "ABCD-1234")
    }

    @Test("a 'license key:' label prefix is stripped")
    internal func licenseKeyLabelPrefixStripped() {
        #expect(StowerLicenseEntryView.normalize("license key: ABCD-1234") == "ABCD-1234")
    }

    @Test("a 'license_key=' query-param prefix is stripped")
    internal func licenseKeyQueryPrefixStripped() {
        #expect(StowerLicenseEntryView.normalize("license_key=ABCD-1234") == "ABCD-1234")
    }

    @Test("a pasted checkout URL keeps only the trailing key segment")
    internal func urlPrefixStripped() {
        #expect(
            StowerLicenseEntryView.normalize("https://app.lemonsqueezy.com/my-orders/ABCD-1234")
                == "ABCD-1234"
        )
    }

    @Test("an empty or whitespace-only string normalizes to empty")
    internal func emptyStaysEmpty() {
        #expect(StowerLicenseEntryView.normalize("   ") == "")
        #expect(StowerLicenseEntryView.normalize("") == "")
    }
}
