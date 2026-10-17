import Foundation

/// Table lookup in the package resource bundle (classic .lproj/.strings:
/// `swift build` copies string catalogs raw without compiling them, so
/// .xcstrings must never be used here).
enum KitStrings {
    static func localized(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
