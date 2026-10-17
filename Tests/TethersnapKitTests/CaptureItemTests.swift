import Foundation
import Testing
@testable import TethersnapKit

@Suite("Capture items")
struct CaptureItemTests {
    @Test
    func `Extensions classify photos, RAW, and videos case-insensitively`() {
        #expect(CaptureItem.kind(forFilename: "photo.JPG") == .image)
        #expect(CaptureItem.kind(forFilename: "IMG_0001.heic") == .image)
        #expect(CaptureItem.kind(forFilename: "shot.webp") == .image)
        #expect(CaptureItem.kind(forFilename: "IMG_0001.CR3") == .image)
        #expect(CaptureItem.kind(forFilename: "DSC_0001.NEF") == .image)
        #expect(CaptureItem.kind(forFilename: "clip.webm") == .video)
        #expect(CaptureItem.kind(forFilename: "clip.MOV") == .video)
        #expect(CaptureItem.kind(forFilename: "clip.m2ts") == .video)
        #expect(CaptureItem.kind(forFilename: "notes.txt") == nil)
        #expect(CaptureItem.kind(forFilename: "noextension") == nil)
    }

    @Test
    func `The PTP object format classifies files without a usable extension`() {
        #expect(CaptureItem.kind(forFilename: "DSC_0001", objectFormat: 0x3801) == .image)
        #expect(CaptureItem.kind(forFilename: "DSC_0001", objectFormat: 0xB982) == .video)
        #expect(CaptureItem.kind(forFilename: "DSC_0001", objectFormat: 0xB103) == nil) // vendor code: ambiguous
        #expect(CaptureItem.kind(forFilename: "clip.mp4", objectFormat: 0x3000) == .video) // extension wins
    }

    @Test
    func `RAW images are flagged, JPEGs and videos are not`() {
        #expect(makeItem("IMG_0001.CR3", kind: .image).isRawImage)
        #expect(makeItem("IMG_0001.dng", kind: .image).isRawImage)
        #expect(!makeItem("IMG_0001.JPG", kind: .image).isRawImage)
        #expect(!makeItem("clip.mp4", kind: .video).isRawImage)
    }

    @Test
    func `Identity is the origin and the accessors follow it`() {
        let ptp = CaptureItem(handle: 0x42, storageID: 0x0001_0001, filename: "a.jpg", kind: .image, sizeInBytes: 1, date: nil)
        let url = URL(fileURLWithPath: "/Volumes/CARD/DCIM/100CANON/a.jpg")
        let file = CaptureItem(origin: .file(url), filename: "a.jpg", kind: .image, sizeInBytes: 1, date: nil)

        #expect(ptp.id == .ptp(handle: 0x42, storageID: 0x0001_0001))
        #expect(ptp.handle == 0x42)
        #expect(ptp.storageID == 0x0001_0001)
        #expect(ptp.fileURL == nil)
        #expect(file.id == .file(url))
        #expect(file.handle == nil)
        #expect(file.storageID == nil)
        #expect(file.fileURL == url)
        #expect(ptp.id != file.id)
        #expect(String(describing: file.origin) == "file:a.jpg") // never the full path
        #expect(String(describing: ptp.origin) == "0x00010001/0x00000042")
    }

    @Test
    func `Filename collisions get numbered export names across origins`() {
        let items = [
            CaptureItem(handle: 1, storageID: 1, filename: "a.jpg", kind: .image, sizeInBytes: 1, date: nil),
            CaptureItem(origin: .file(URL(fileWithPath: "/x/A.JPG")), filename: "A.JPG", kind: .image, sizeInBytes: 1, date: nil),
            CaptureItem(handle: 2, storageID: 1, filename: "b.jpg", kind: .image, sizeInBytes: 1, date: nil),
            CaptureItem(handle: 3, storageID: 2, filename: "a.jpg", kind: .image, sizeInBytes: 1, date: nil),
        ]

        let resolved = items.resolvingFilenameCollisions()

        #expect(resolved.map(\.exportFilename) == ["a.jpg", "A-2.JPG", "b.jpg", "a-3.jpg"])
        #expect(resolved.map(\.filename) == items.map(\.filename))
    }

    private func makeItem(_ filename: String, kind: CaptureItem.Kind) -> CaptureItem {
        CaptureItem(origin: .file(URL(fileWithPath: "/x/\(filename)")), filename: filename, kind: kind, sizeInBytes: 1, date: nil)
    }
}

private extension URL {
    init(fileWithPath path: String) {
        self.init(fileURLWithPath: path)
    }
}
