import Foundation

/// Table lookup in the package resource bundle (classic .lproj/.strings:
/// `swift build` copies string catalogs raw without compiling them, so
/// .xcstrings must never be used here). The bundle is found through
/// `PackageResources`: the generated `Bundle.module` alone only works on the
/// machine that built the app.
enum KitStrings {
    private static let bundle = PackageResources.bundle(named: "Tethersnap_TethersnapKit") { Bundle.module }

    static func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
