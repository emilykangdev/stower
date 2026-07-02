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

    // MARK: - Key-format gate (isPlausibleKey)

    @Test("a well-formed UUID license key is plausible")
    internal func wellFormedUUIDIsPlausible() {
        #expect(StowerLicenseEntryView.isPlausibleKey("80e15db5-c796-436b-850c-8f9c98a48abe"))
        // Case-insensitive — Lemon Squeezy keys are lowercase, but a user may
        // paste an upper/mixed-case copy.
        #expect(StowerLicenseEntryView.isPlausibleKey("80E15DB5-C796-436B-850C-8F9C98A48ABE"))
    }

    @Test("a UUID key with paste junk is still plausible after normalization")
    internal func uuidWithJunkIsPlausible() {
        #expect(
            StowerLicenseEntryView.isPlausibleKey("  key: 80e15db5-c796-436b-850c-8f9c98a48abe\n")
        )
    }

    @Test("a single stray character is NOT plausible (blocks a pointless /activate)")
    internal func strayCharacterIsNotPlausible() {
        #expect(!StowerLicenseEntryView.isPlausibleKey("a"))
        #expect(!StowerLicenseEntryView.isPlausibleKey(""))
        #expect(!StowerLicenseEntryView.isPlausibleKey("   "))
    }

    @Test("a malformed key (wrong segments, non-hex, truncated) is NOT plausible")
    internal func malformedKeyIsNotPlausible() {
        // Too short / non-hex.
        #expect(!StowerLicenseEntryView.isPlausibleKey("ABCD-1234"))
        // No hyphens.
        #expect(!StowerLicenseEntryView.isPlausibleKey("80e15db5c796436b850c8f9c98a48abe"))
        // 11-digit tail (needs 12).
        #expect(!StowerLicenseEntryView.isPlausibleKey("80e15db5-c796-436b-850c-8f9c98a48ab"))
        // Non-hex characters.
        #expect(!StowerLicenseEntryView.isPlausibleKey("zzzzzzzz-c796-436b-850c-8f9c98a48abe"))
    }
}
