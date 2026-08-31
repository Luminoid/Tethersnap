import Foundation
import Testing
@testable import TethersnapKit

@Suite("Localization")
struct LocalizationTests {
    @Test
    func `English error strings resolve instead of echoing their keys`() throws {
        let description = try #require(MTPError.deviceNotFound.errorDescription)

        #expect(description != "error.device_not_found")
        #expect(description.contains("Switch 2"))
    }

    @Test
    func `Errors with arguments substitute them into the localized format`() throws {
        let mismatch = try #require(MTPError.transactionMismatch(expected: 7, received: 9).errorDescription)
        let response = try #require(MTPError.deviceResponse(.invalidObjectHandle).errorDescription)

        #expect(mismatch.contains("7"))
        #expect(mismatch.contains("9"))
        #expect(response.contains("InvalidObjectHandle"))
    }

    @Test
    func `The zh-Hans table exists and translates every error key`() throws {
        let chinese = try lprojBundle("zh-Hans")
        let english = try lprojBundle("en")
        let keys = [
            "error.device_not_found", "error.claim_failed", "error.underlying",
            "error.no_mtp_interface", "error.transfer_failed", "error.malformed_data",
            "error.device_response", "error.transaction_mismatch", "error.session_invalidated",
            "error.stale_session_reset",
            "storage.default",
        ]

        for key in keys {
            let zhValue = chinese.localizedString(forKey: key, value: "MISSING", table: nil)
            let enValue = english.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(zhValue != "MISSING", "zh-Hans missing \(key)")
            #expect(enValue != "MISSING", "en missing \(key)")
            #expect(zhValue != enValue, "\(key) is untranslated")
        }
        #expect(chinese.localizedString(forKey: "error.device_not_found", value: nil, table: nil).contains("Switch 2"))
    }

    @Test
    func `A zh-Hans user preference selects the Chinese localization`() {
        let picks = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: ["zh-Hans-CN"])

        #expect(picks.first?.lowercased() == "zh-hans")
    }

    @Test
    func `Format placeholders match between English and Chinese`() throws {
        let chinese = try lprojBundle("zh-Hans")
        let english = try lprojBundle("en")
        let formatKeys = [
            "error.claim_failed", "error.underlying", "error.transfer_failed",
            "error.malformed_data", "error.device_response", "error.transaction_mismatch",
        ]

        for key in formatKeys {
            let zhCount = placeholderCount(chinese.localizedString(forKey: key, value: "", table: nil))
            let enCount = placeholderCount(english.localizedString(forKey: key, value: "", table: nil))
            #expect(zhCount == enCount, "\(key): en has \(enCount) placeholders, zh-Hans has \(zhCount)")
            #expect(enCount > 0, "\(key) should carry at least one placeholder")
        }
    }

    /// SPM lowercases lproj directory names (zh-Hans → zh-hans.lproj); locale
    /// matching is case-insensitive, but direct path lookups must tolerate it.
    private func lprojBundle(_ name: String) throws -> Bundle {
        for candidate in [name, name.lowercased()] {
            let url = Bundle.module.bundleURL.appendingPathComponent("\(candidate).lproj")
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        throw MTPError.malformedData("missing \(name).lproj in test bundle")
    }

    private func placeholderCount(_ format: String) -> Int {
        // Counts %@ / %lld style placeholders, positional or not.
        let pattern = /%(\d+\$)?(@|lld|d|u|s)/
        return format.matches(of: pattern).count
    }
}
