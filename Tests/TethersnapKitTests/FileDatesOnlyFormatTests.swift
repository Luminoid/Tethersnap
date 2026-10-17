import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TethersnapKit

/// Which formats get an embedded date and which get Finder dates only.
@Suite("Date-fix format coverage")
struct FileDatesOnlyFormatTests {
    /// HEIC is in the rewritable set because this holds: ImageIO stores the
    /// EXIF date in the HEIF container and reads it back (the XMP tree stays
    /// empty, which is why the writer also consults the EXIF property
    /// dictionary). The fixer verifies every image rewrite the same way.
    @Test
    func `A HEIC gains an embedded date that reads back`() throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("IMG_20260830_123456.heic")
        try ImageDateWriterTests.writeFixture(at: url, type: .heic)

        #expect(try ImageDateWriter.embeddedDate(at: url) == nil)
        try ImageDateWriter.write(ImageDateWriterTests.fixtureDate, to: url)

        let readBack = try #require(try ImageDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(ImageDateWriterTests.fixtureDate)) < 1)
    }

    @Test
    func `RAW, WebP, GIF, BMP, WebM, AVI, and MTS get Finder dates only`() async throws {
        let folder = try VolumeFixtures.makeRoot("fileDatesOnly")
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = [
            "IMG_20260830_123457.CR3", "IMG_20260830_123458.webp", "20260830123459_1.gif",
            "20260830123500_1.bmp", "Game_20260830123501.webm", "Game_20260830123502.avi", "Game_20260830123503.mts",
        ]
        try VolumeFixtures.populate(folder, names, contents: Data([0x00, 0x01, 0x02]))

        let report = await CaptureDateFixer().fix(folder: folder)

        #expect(report.entries.count == names.count)
        #expect(report.failed.isEmpty)
        for entry in report.entries {
            guard case let .updated(_, embedded) = entry.outcome else {
                Issue.record("\(entry.url.lastPathComponent): \(entry.outcome)")
                continue
            }
            #expect(!embedded, "\(entry.url.lastPathComponent)")
            #expect(try Data(contentsOf: entry.url) == Data([0x00, 0x01, 0x02]), "bytes must never be rewritten")
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.url.path)
            let created = try #require(attributes[.creationDate] as? Date)
            let expected = try #require(FilenameDate.parse(entry.url.lastPathComponent))
            #expect(abs(created.timeIntervalSince(expected)) < 1, "\(entry.url.lastPathComponent)")
        }
        // Finder-dates-only files report `updated` on every run by design, never `alreadyDated`.
        let again = await CaptureDateFixer().fix(folder: folder)
        #expect(again.alreadyDated.isEmpty)
        #expect(again.updated.count == names.count)
    }

    @Test
    func `A stale date-rewrite temp from a killed run is reaped before fixing`() async throws {
        let folder = try VolumeFixtures.makeRoot("staleTemp")
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Game_20260830123456.webm")
        try Data([1]).write(to: original)
        let stale = TemporaryFiles.dateRewriteURL(for: original)
        try Data([2]).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        let fresh = TemporaryFiles.partialURL(for: folder.appendingPathComponent("active.mp4"))
        try Data([3]).write(to: fresh) // being written right now: mtime is new

        _ = await CaptureDateFixer().fix(folder: folder)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}
