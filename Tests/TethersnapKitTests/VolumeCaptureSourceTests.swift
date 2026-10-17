import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TethersnapKit

@Suite("Volume capture source")
struct VolumeCaptureSourceTests {
    @Test
    func `A PS5 drive lists its captures by game and ignores everything else`() throws {
        let root = try VolumeFixtures.makeRoot("ps5")
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, [
            "PS5/CREATE/Screenshots/Astro/Astro_20260830123456.jpg",
            "PS5/CREATE/Screenshots/Astro/notes.txt",
            "PS5/CREATE/Screenshots/Astro/.hidden.jpg",
            "PS5/CREATE/Video Clips/Astro/Astro_20260830123500.webm",
            "PS5/CREATE/Video Clips/Returnal/Returnal_20260901080000.mp4",
            "System Volume Information/stray.jpg",
            "stray.png",
        ])

        let source = try VolumeCaptureSource(root: root)
        // Enumeration order is the filesystem's (callers sort); compare by name.
        let items = try source.loadItems().sorted { $0.filename < $1.filename }

        #expect(source.layout == .ps5)
        #expect(source.descriptor.kind == .folder)
        #expect(items.map(\.filename) == ["Astro_20260830123456.jpg", "Astro_20260830123500.webm", "Returnal_20260901080000.mp4"])
        #expect(items.map(\.folderName) == ["Astro", "Astro", "Returnal"])
        #expect(items.map(\.kind) == [.image, .video, .video])
        #expect(items[0].sizeInBytes == Int64("PS5/CREATE/Screenshots/Astro/Astro_20260830123456.jpg".utf8.count))
        #expect(items[0].fileURL?.lastPathComponent == "Astro_20260830123456.jpg")
    }

    @Test
    func `Dates come from the filename first, then the file`() throws {
        let root = try VolumeFixtures.makeRoot("dates")
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, ["2026082917051200-CAFE.jpg", "IMG_0001.JPG"])

        let items = try VolumeCaptureSource(root: root).loadItems()

        let named = try #require(items.first { $0.filename == "2026082917051200-CAFE.jpg" })
        var components = try Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: #require(named.date))
        components.calendar = nil
        #expect(components == DateComponents(year: 2026, month: 8, day: 29, hour: 17, minute: 5, second: 12))
        let unnamed = try #require(items.first { $0.filename == "IMG_0001.JPG" })
        #expect(try abs(#require(unnamed.date).timeIntervalSinceNow) < 60) // the file's own creation date
    }

    @Test
    func `A generic walk skips housekeeping folders and stops at the depth cap`() throws {
        let root = try VolumeFixtures.makeRoot("generic")
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, [
            "20260830123456_1.jpg",
            "exports/20260830123457_1.png",
            ".Trashes/old.jpg",
            "$RECYCLE.BIN/old.jpg",
            "a/b/c/d/e/f/ok.jpg",
            "a/b/c/d/e/f/g/deep.jpg",
        ])

        let items = try VolumeCaptureSource(root: root).loadItems()

        #expect(Set(items.map(\.filename)) == ["20260830123456_1.jpg", "20260830123457_1.png", "ok.jpg"])
        #expect(items.first { $0.filename == "20260830123456_1.jpg" }?.folderName == nil)
        #expect(items.first { $0.filename == "20260830123457_1.png" }?.folderName == "exports")
    }

    @Test
    func `Same-named files in two camera folders get numbered export names`() throws {
        let root = try VolumeFixtures.makeRoot("dcim")
        defer { try? FileManager.default.removeItem(at: root) }
        try VolumeFixtures.populate(root, ["DCIM/100CANON/IMG_0001.JPG", "DCIM/101CANON/IMG_0001.JPG"])

        let items = try VolumeCaptureSource(root: root).loadItems()

        #expect(items.map(\.exportFilename) == ["IMG_0001.JPG", "IMG_0001-2.JPG"])
        #expect(items.map(\.folderName) == ["100CANON", "101CANON"])
    }

    @Test
    func `Download copies the bytes, stamps the date, skips same-size files, and honors cancel`() throws {
        let root = try VolumeFixtures.makeRoot("download")
        let destination = try VolumeFixtures.makeRoot("export")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let body = Data((0 ..< 3_000_000).map { UInt8($0 % 251) }) // crosses the 1 MiB chunk size
        try VolumeFixtures.populate(root, ["2026082917051200-CAFE.jpg"], contents: body)
        let source = try VolumeCaptureSource(root: root)
        let item = try #require(try source.loadItems().first)

        var reports: [Int64] = []
        let result = try source.download(item, to: destination, skipExisting: false, cancelToken: nil) { written, _ in reports.append(written) }
        #expect(!result.skippedExisting)
        #expect(try Data(contentsOf: result.url) == body)
        #expect(reports.last == Int64(body.count))
        #expect(reports.count >= 3)
        let modification = try #require(FileManager.default.attributesOfItem(atPath: result.url.path)[.modificationDate] as? Date)
        #expect(try abs(modification.timeIntervalSince(#require(item.date))) < 1)

        let skipped = try source.download(item, to: destination, skipExisting: true, cancelToken: nil, progress: nil)
        #expect(skipped.skippedExisting)

        let token = CancelToken()
        token.cancel()
        try FileManager.default.removeItem(at: result.url)
        #expect(throws: CancellationError.self) {
            try source.download(item, to: destination, skipExisting: false, cancelToken: token, progress: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test
    func `imageData reads the file and a vanished file is an unreadable-file error`() throws {
        let root = try VolumeFixtures.makeRoot("read")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try VolumeFixtures.populate(root, ["shot.png"], contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let source = try VolumeCaptureSource(root: root)
        let item = try #require(try source.loadItems().first)

        #expect(try source.imageData(for: item) == Data([0x89, 0x50, 0x4E, 0x47]))

        try FileManager.default.removeItem(at: urls[0])
        #expect(throws: CaptureSourceError.self) { try source.imageData(for: item) }
    }

    @Test
    func `Foreign items are rejected and a removed root invalidates the source`() throws {
        let root = try VolumeFixtures.makeRoot("foreign")
        let source = try VolumeCaptureSource(root: root)
        let ptpItem = CaptureItem(handle: 1, storageID: 1, filename: "a.jpg", kind: .image, sizeInBytes: 1, date: nil)

        #expect(throws: CaptureSourceError.self) { try source.imageData(for: ptpItem) }
        #expect(source.isValid)

        try FileManager.default.removeItem(at: root)
        #expect(!source.isValid)
        #expect(throws: CaptureSourceError.self) { try source.loadItems() }
    }

    @Test
    func `A folder that does not exist cannot be opened`() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-missing-\(UUID().uuidString)")
        #expect(throws: CaptureSourceError.self) { try VolumeCaptureSource(root: missing) }
    }

    @Test
    func `Image thumbnails are bounded JPEGs and unreadable videos yield nil`() throws {
        let root = try VolumeFixtures.makeRoot("thumbs")
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("20260830123456_1.png")
        try Self.writePNG(width: 1200, height: 800, to: png)
        try VolumeFixtures.populate(root, ["Game_20260830123500.webm"], contents: Data(repeating: 0x1A, count: 64))
        let source = try VolumeCaptureSource(root: root)
        let items = try source.loadItems()
        let image = try #require(items.first { $0.kind == .image })
        let video = try #require(items.first { $0.kind == .video })

        let payload = try #require(try source.thumbnailPayload(for: image))
        #expect(payload.isComplete)
        #expect(payload.data.prefix(2) == Data([0xFF, 0xD8]))
        let decoded = try #require(CGImageSourceCreateWithData(payload.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let bound = VolumeThumbnailer.maxPixelSize
        #expect(decoded.width <= bound && decoded.height <= bound)
        #expect(decoded.width == bound)

        #expect(try source.thumbnailPayload(for: video) == nil)
    }

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
