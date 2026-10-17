import Foundation
import Testing
@testable import TethersnapKit

@Suite("Capture item collisions")
struct CaptureItemCollisionTests {
    private func item(_ filename: String, handle: UInt32) -> CaptureItem {
        CaptureItem(handle: handle, storageID: 0x0001_0001, filename: filename, kind: .image, sizeInBytes: 1, date: nil)
    }

    @Test
    func `A generated export name never collides with a later original`() {
        let items = [item("shot.jpg", handle: 1), item("shot.jpg", handle: 2), item("shot-2.jpg", handle: 3)]

        let resolved = items.resolvingFilenameCollisions()

        #expect(resolved.map(\.exportFilename) == ["shot.jpg", "shot-3.jpg", "shot-2.jpg"])
        #expect(Set(resolved.map { $0.exportFilename.lowercased() }).count == 3)
    }

    @Test
    func `Collisions are case-insensitive and keep the extension`() {
        let items = [item("IMG_0001.JPG", handle: 1), item("img_0001.jpg", handle: 2), item("noext", handle: 3), item("noext", handle: 4)]

        let resolved = items.resolvingFilenameCollisions()

        #expect(resolved.map(\.exportFilename) == ["IMG_0001.JPG", "img_0001-2.jpg", "noext", "noext-2"])
    }

    @Test
    func `sortedNewestFirst puts undated items last`() {
        let now = Date()
        var dated = item("b.jpg", handle: 1)
        dated = CaptureItem(origin: dated.origin, filename: dated.filename, kind: .image, sizeInBytes: 1, date: now)
        let older = CaptureItem(origin: .ptp(handle: 2, storageID: 1), filename: "a.jpg", kind: .image, sizeInBytes: 1, date: now.addingTimeInterval(-60))
        let undated = item("c.jpg", handle: 3)

        let sorted = [undated, older, dated].sortedNewestFirst()

        #expect(sorted.map(\.filename) == ["b.jpg", "a.jpg", "c.jpg"])
    }
}
