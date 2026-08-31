import Foundation
import Testing
@testable import TethersnapKit

/// The app target has no test target of its own, so its string tables are
/// checked here by parsing the .strings files straight from the repo (keyed
/// off `#filePath`): a key added to one locale but not the other would
/// otherwise ship silently as untranslated English.
@Suite("App localization tables")
struct AppLocalizationTests {
    private static let halfwidthPunctuation: Set<Character> = ["(", ")", ":", ";", ","]

    @Test
    func `English and Chinese app tables carry identical key sets`() throws {
        let english = try Self.table("en")
        let chinese = try Self.table("zh-Hans")

        let missingInChinese = Set(english.keys).subtracting(chinese.keys).sorted()
        let missingInEnglish = Set(chinese.keys).subtracting(english.keys).sorted()
        #expect(missingInChinese.isEmpty, "keys missing from zh-Hans: \(missingInChinese)")
        #expect(missingInEnglish.isEmpty, "keys missing from en: \(missingInEnglish)")
        #expect(english.count > 40)
    }

    @Test
    func `Format placeholders match per key across app locales`() throws {
        let english = try Self.table("en")
        let chinese = try Self.table("zh-Hans")

        for (key, enValue) in english {
            guard let zhValue = chinese[key] else { continue }
            let enPlaceholders = Self.placeholders(enValue)
            let zhPlaceholders = Self.placeholders(zhValue)
            #expect(enPlaceholders == zhPlaceholders, "\(key): en \(enPlaceholders) vs zh-Hans \(zhPlaceholders)")
        }
    }

    @Test
    func `Chinese app strings use fullwidth punctuation`() throws {
        let chinese = try Self.table("zh-Hans")

        for (key, value) in chinese {
            let offenders = value.filter { Self.halfwidthPunctuation.contains($0) }
            #expect(offenders.isEmpty, "\(key) contains halfwidth punctuation: \(value)")
        }
    }

    @Test
    func `App tables actually differ between locales`() throws {
        let english = try Self.table("en")
        let chinese = try Self.table("zh-Hans")

        let untranslated = english.filter { key, value in
            // Brand-name-only values may legitimately match.
            chinese[key] == value && value.rangeOfCharacter(from: .letters) != nil && value != "Tethersnap"
        }
        #expect(untranslated.isEmpty, "identical values in both locales: \(untranslated.keys.sorted())")
    }

    /// Sorted multiset of placeholder tokens, position markers stripped.
    private static func placeholders(_ format: String) -> [String] {
        format.matches(of: /%(\d+\$)?(@|lld|d|u|s)/).map { String($0.output.2) }.sorted()
    }

    private static func table(_ locale: String) throws -> [String: String] {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let stringsFile = testsDir
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/TethersnapApp/Resources/\(locale).lproj/Localizable.strings")
        guard let dictionary = NSDictionary(contentsOf: stringsFile) as? [String: String] else {
            throw MTPError.malformedData("could not parse \(stringsFile.path)")
        }
        return dictionary
    }
}
