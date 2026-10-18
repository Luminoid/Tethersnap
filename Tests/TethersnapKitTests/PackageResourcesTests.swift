import Foundation
import Testing
@testable import TethersnapKit

/// The resource-bundle lookup that replaced bare `Bundle.module`: a shipped app
/// keeps its bundles in `Contents/Resources`, which the generated accessor
/// never checks (issue #1).
@Suite("Package resources")
struct PackageResourcesTests {
    @Test
    func `the first directory holding the bundle wins and a missing bundle is nil`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("tethersnap-resources-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second.appendingPathComponent("Foo.bundle"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let found = PackageResources.bundle(named: "Foo", in: [first, second])
        let expected = second.appendingPathComponent("Foo.bundle").resolvingSymlinksInPath().path
        #expect(found?.bundleURL.resolvingSymlinksInPath().path == expected)
        #expect(PackageResources.bundle(named: "Bar", in: [first, second]) == nil)
        // A plain file of the right name is not a bundle.
        try Data().write(to: first.appendingPathComponent("Baz.bundle"))
        #expect(PackageResources.bundle(named: "Baz", in: [first]) == nil)
    }

    @Test
    func `the search starts in the main bundle's Resources folder, then beside the executable`() {
        let directories = PackageResources.searchDirectories(main: .main)
        #expect(directories.first == Bundle.main.resourceURL)
        #expect(directories.last == Bundle.main.bundleURL)
    }

    @Test
    func `the fallback runs only when no shipped bundle exists`() {
        var fallbackCalls = 0
        let bundle = PackageResources.bundle(named: "Tethersnap_NoSuchBundle") {
            fallbackCalls += 1
            return Bundle.main
        }
        #expect(bundle == Bundle.main)
        #expect(fallbackCalls == 1)
    }
}
