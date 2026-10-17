import Foundation
import Testing
@testable import TethersnapKit

/// The kit's string tables, checked two ways: through the resource bundle
/// (what the error enums see at runtime) and by parsing both `.strings` files
/// from the repo, so a key added to one locale but not the other, or added to
/// both but forgotten here, cannot slip through.
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
        let filename = try #require(CaptureSourceError.invalidFilename("..").errorDescription)

        #expect(mismatch.contains("7"))
        #expect(mismatch.contains("9"))
        #expect(response.contains("InvalidObjectHandle"))
        #expect(filename.contains(".."))
    }

    @Test
    func `Both kit tables carry the same keys and every key resolves in both bundles`() throws {
        let english = try Self.table("en")
        let chinese = try Self.table("zh-Hans")
        let englishBundle = try lprojBundle("en")
        let chineseBundle = try lprojBundle("zh-Hans")

        #expect(Set(english.keys) == Set(chinese.keys), "key sets differ: \(Set(english.keys).symmetricDifference(chinese.keys).sorted())")
        #expect(english.count >= 20)
        for key in english.keys.sorted() {
            let zhValue = chineseBundle.localizedString(forKey: key, value: "MISSING", table: nil)
            let enValue = englishBundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(zhValue != "MISSING", "zh-Hans bundle missing \(key)")
            #expect(enValue != "MISSING", "en bundle missing \(key)")
            #expect(zhValue != enValue, "\(key) is untranslated")
        }
        #expect(chineseBundle.localizedString(forKey: "error.device_not_found", value: nil, table: nil).contains("Switch 2"))
    }

    @Test
    func `A zh-Hans user preference selects the Chinese localization`() {
        let picks = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: ["zh-Hans-CN"])

        #expect(picks.first?.lowercased() == "zh-hans")
    }

    @Test
    func `Format placeholders match between English and Chinese for every key`() throws {
        let english = try Self.table("en")
        let chinese = try Self.table("zh-Hans")

        for (key, enValue) in english {
            guard let zhValue = chinese[key] else { continue }
            let enPlaceholders = Self.placeholders(enValue)
            let zhPlaceholders = Self.placeholders(zhValue)
            #expect(enPlaceholders == zhPlaceholders, "\(key): en \(enPlaceholders) vs zh-Hans \(zhPlaceholders)")
        }
        // The keys the code formats must actually carry a placeholder.
        for key in ["error.claim_failed", "error.unreadable_file", "error.invalid_filename", "error.datefix.not_a_folder"] {
            #expect(!Self.placeholders(english[key] ?? "").isEmpty, "\(key) should carry at least one placeholder")
        }
    }

    @Test
    func `Chinese kit strings use fullwidth punctuation`() throws {
        let halfwidth: Set<Character> = ["(", ")", ":", ";", ","]
        for (key, value) in try Self.table("zh-Hans") {
            // Arrows and setting paths quote the UI; the characters around them must still be fullwidth.
            let offenders = value.filter { halfwidth.contains($0) }
            #expect(offenders.isEmpty, "\(key) contains halfwidth punctuation: \(value)")
        }
    }

    /// SPM lowercases lproj directory names (zh-Hans → zh-hans.lproj); locale
    /// matching is case-insensitive, but direct path lookups must tolerate it.
    /// `resourceURL` covers both bundle layouts: the flat one and the Swift Build
    /// backend's `Contents/Resources/`.
    private func lprojBundle(_ name: String) throws -> Bundle {
        let resources = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        for candidate in [name, name.lowercased()] {
            let url = resources.appendingPathComponent("\(candidate).lproj")
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        throw MTPError.malformedData("missing \(name).lproj in test bundle")
    }

    /// The `.strings` file as checked in, keyed off `#filePath` like the app table test.
    private static func table(_ locale: String) throws -> [String: String] {
        let stringsFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TethersnapKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/TethersnapKit/Resources/\(locale).lproj/Localizable.strings")
        guard let dictionary = NSDictionary(contentsOf: stringsFile) as? [String: String] else {
            throw MTPError.malformedData("could not parse \(stringsFile.path)")
        }
        return dictionary
    }

    /// Sorted multiset of placeholder tokens, position markers stripped.
    private static func placeholders(_ format: String) -> [String] {
        format.matches(of: /%(\d+\$)?(@|lld|d|u|s)/).map { String($0.output.2) }.sorted()
    }
}
