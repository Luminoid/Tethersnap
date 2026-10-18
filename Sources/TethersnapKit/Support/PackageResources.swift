import Foundation

/// Finds a SwiftPM resource bundle where a shipped product keeps it.
///
/// The `Bundle.module` accessor that `swift build` generates looks in two
/// places: `<name>.bundle` under `Bundle.main.bundleURL` (an app's root, or a
/// command-line binary's folder) and the absolute `.build` path of the machine
/// that built it, then traps. `make app` ships the bundles in
/// `Contents/Resources`, so on every Mac but the build machine the app crashed
/// at its first string lookup (issue #1, 0.1.0 and 0.2.0). The search below
/// starts where the app and the CLI actually carry their bundles and leaves the
/// generated accessor as the last resort, which still serves `swift run`,
/// `swift test`, and Xcode, where the build path exists.
package enum PackageResources {
    /// The bundle named `name` (without `.bundle`) from the shipped locations,
    /// else whatever `fallback` yields.
    package static func bundle(named name: String, fallback: () -> Bundle) -> Bundle {
        bundle(named: name, in: searchDirectories()) ?? fallback()
    }

    /// Where a shipped product keeps its resource bundles, in search order: the
    /// app's `Contents/Resources`, then the folder of the main executable (a
    /// command-line binary's bundles sit beside it).
    static func searchDirectories(main: Bundle = .main) -> [URL] {
        var directories: [URL] = []
        if let resources = main.resourceURL {
            directories.append(resources)
        }
        directories.append(main.bundleURL)
        return directories
    }

    /// The first `<name>.bundle` directory found under `directories`.
    static func bundle(named name: String, in directories: [URL]) -> Bundle? {
        for directory in directories {
            let url = directory.appendingPathComponent("\(name).bundle", isDirectory: true)
            if FileSystem.isDirectory(url), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}
