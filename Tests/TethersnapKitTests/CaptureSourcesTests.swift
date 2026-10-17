import Foundation
import Testing
@testable import TethersnapKit

/// The parts of source discovery and opening that need no hardware.
@Suite("Capture sources")
struct CaptureSourcesTests {
    @Test
    func `openFolder yields a folder source whose descriptor id is its path`() throws {
        let root = try VolumeFixtures.makeRoot("open")
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, ["20260830123456_1.jpg"])

        let source = try CaptureSources.openFolder(root)
        defer { source.close() }

        #expect(source.descriptor.kind == .folder)
        #expect(source.descriptor.id == "folder:\(root.standardizedFileURL.path)")
        #expect(source.isValid)
        #expect(try source.loadItems().map(\.filename) == ["20260830123456_1.jpg"])
    }

    @Test
    func `open with a folder location is the same as openFolder`() throws {
        let root = try VolumeFixtures.makeRoot("open-descriptor")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try CaptureSources.open(.folder(root))
        defer { source.close() }

        #expect(source.descriptor == CaptureSourceDescriptor.folder(root))
    }

    @Test
    func `A missing folder fails to open with sourceUnavailable`() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-missing-\(UUID().uuidString)")

        #expect {
            _ = try CaptureSources.openFolder(missing)
        } throws: { error in
            if case CaptureSourceError.sourceUnavailable = error { true } else { false }
        }
    }

    @Test
    func `A volume source stops at its item limit`() throws {
        let root = try VolumeFixtures.makeRoot("limit")
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, (1 ... 5).map { "2026083012345\($0)_1.jpg" })

        let items = try VolumeCaptureSource(root: root, itemLimit: 3).loadItems()

        #expect(items.count == 3)
    }
}
