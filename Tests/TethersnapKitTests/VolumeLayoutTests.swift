import Foundation
import Testing
@testable import TethersnapKit

/// Builds throwaway directory trees for the volume tests.
enum VolumeFixtures {
    static func makeRoot(_ name: String = "volume") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Creates every relative path; entries ending in `/` are directories,
    /// files get `contents` (their relative path's UTF-8 by default).
    @discardableResult
    static func populate(_ root: URL, _ paths: [String], contents: Data? = nil) throws -> [URL] {
        var urls: [URL] = []
        for path in paths {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (contents ?? Data(path.utf8)).write(to: url)
            }
            urls.append(url)
        }
        return urls
    }
}

@Suite("Volume layouts")
struct VolumeLayoutTests {
    @Test
    func `Detection follows the marker folders with console layouts first`() throws {
        let root = try VolumeFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(VolumeLayout.detect(root: root) == .generic)
        try VolumeFixtures.populate(root, ["DCIM/100CANON/"])
        #expect(VolumeLayout.detect(root: root) == .dcim)
        try VolumeFixtures.populate(root, ["Nintendo/Album/2026/08/29/"])
        #expect(VolumeLayout.detect(root: root) == .switchAlbum)
        try VolumeFixtures.populate(root, ["PS4/SHARE/Screenshots/"])
        #expect(VolumeLayout.detect(root: root) == .ps4)
        try VolumeFixtures.populate(root, ["PS5/CREATE/Screenshots/"])
        #expect(VolumeLayout.detect(root: root) == .ps5)
    }

    @Test
    func `Media roots are the layout's capture folders that exist`() throws {
        let root = try VolumeFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, ["PS5/CREATE/Screenshots/Astro/"])

        let roots = VolumeLayout.ps5.mediaRoots(under: root)

        #expect(roots.map(\.lastPathComponent) == ["Screenshots"]) // no Video Clips folder yet
        #expect(VolumeLayout.generic.mediaRoots(under: root) == [root])
    }

    @Test
    func `A Sony card scans DCIM and the XAVC clip folder, not proxies or thumbnails`() throws {
        let root = try VolumeFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, ["DCIM/100MSDCF/", "PRIVATE/M4ROOT/CLIP/", "PRIVATE/M4ROOT/SUB/", "PRIVATE/M4ROOT/THMBNL/"])

        #expect(VolumeLayout.detect(root: root) == .dcim)
        #expect(VolumeLayout.dcim.mediaRoots(under: root).map(\.lastPathComponent) == ["DCIM", "CLIP"])
    }

    @Test
    func `Folder names follow each layout's grouping rule`() {
        let root = URL(fileURLWithPath: "/Volumes/CARD")
        let ps5 = root.appendingPathComponent("PS5/CREATE/Screenshots")
        #expect(VolumeLayout.ps5.folderName(for: ps5.appendingPathComponent("ASTRO's PLAYROOM/ASTRO's PLAYROOM_20260830123456.jpg"), mediaRoot: ps5) == "ASTRO's PLAYROOM")

        let album = root.appendingPathComponent("Nintendo/Album")
        #expect(VolumeLayout.switchAlbum.folderName(for: album.appendingPathComponent("2026/08/29/2026082917051200-CAFE.jpg"), mediaRoot: album) == "2026-08-29")

        let dcim = root.appendingPathComponent("DCIM")
        #expect(VolumeLayout.dcim.folderName(for: dcim.appendingPathComponent("100CANON/IMG_0001.JPG"), mediaRoot: dcim) == "100CANON")
        let clip = root.appendingPathComponent("PRIVATE/M4ROOT/CLIP")
        #expect(VolumeLayout.dcim.folderName(for: clip.appendingPathComponent("C0001.MP4"), mediaRoot: clip) == "CLIP")

        #expect(VolumeLayout.generic.folderName(for: root.appendingPathComponent("exports/20260830123456_1.jpg"), mediaRoot: root) == "exports")
        #expect(VolumeLayout.generic.folderName(for: root.appendingPathComponent("20260830123456_1.jpg"), mediaRoot: root) == nil)
    }

    @Test
    func `Only the generic layout caps the walk depth`() {
        #expect(VolumeLayout.generic.maxDepth == 6)
        #expect(VolumeLayout.ps5.maxDepth == nil)
        #expect(VolumeLayout.dcim.maxDepth == nil)
    }
}
