import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TethersnapKit

@Suite("Image date writer")
struct ImageDateWriterTests {
    @Test
    func `A JPEG without EXIF gains DateTimeOriginal in EXIF form and keeps its pixels`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026083012345600-CAFE.jpg")
        try Self.writeFixture(at: url, type: .jpeg)
        let before = try Self.pixelBytes(at: url)
        let date = Self.fixtureDate

        #expect(try ImageDateWriter.embeddedDate(at: url) == nil)
        try ImageDateWriter.write(date, to: url)

        #expect(Self.exifDateTimeOriginal(at: url) == "2026:08:30 12:34:56")
        #expect(try Self.pixelBytes(at: url) == before)
        let readBack = try #require(try ImageDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(date)) < 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".2026083012345600-CAFE.jpg.tethersnap-dates").path))
    }

    @Test
    func `A PNG gains an XMP CreateDate and keeps its pixels`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Screenshot 2026-08-30 at 12.34.56 PM.png")
        try Self.writeFixture(at: url, type: .png)
        let before = try Self.pixelBytes(at: url)
        let date = Self.fixtureDate

        #expect(try ImageDateWriter.embeddedDate(at: url) == nil)
        try ImageDateWriter.write(date, to: url)

        let xmp = try #require(Self.metadataString(at: url, path: "xmp:CreateDate"))
        #expect(xmp.hasPrefix("2026-08-30T12:34:56"), "\(xmp)")
        if let exif = Self.exifDateTimeOriginal(at: url) {
            #expect(exif == "2026:08:30 12:34:56")
        }
        #expect(try Self.pixelBytes(at: url) == before)
        let readBack = try #require(try ImageDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(date)) < 1)
    }

    @Test
    func `An embedded EXIF date is read back, honoring OffsetTimeOriginal`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dated.jpg")
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:08:30 12:34:56",
            kCGImagePropertyExifOffsetTimeOriginal: "+08:00",
        ]
        try Self.writeFixture(at: url, type: .jpeg, properties: [kCGImagePropertyExifDictionary: exif])

        let date = try #require(try ImageDateWriter.embeddedDate(at: url))

        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let parts = shanghai.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 30)
        #expect(parts.hour == 12)
        #expect(parts.minute == 34)
        #expect(parts.second == 56)
    }

    @Test
    func `Writing a new date replaces an existing one`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dated.jpg")
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2020:01:01 00:00:00"]
        try Self.writeFixture(at: url, type: .jpeg, properties: [kCGImagePropertyExifDictionary: exif])

        try ImageDateWriter.write(Self.fixtureDate, to: url)

        #expect(Self.exifDateTimeOriginal(at: url) == "2026:08:30 12:34:56")
    }

    @Test
    func `A TIFF modification time alone is not a capture date`() throws {
        // The original Switch stamps only TIFF DateTime (0x0132), which ImageIO
        // surfaces as xmp:ModifyDate; such a file is undated and gains one.
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026083012345600_s.jpg")
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFDateTime: "2026:08:30 12:34:56"]
        try Self.writeFixture(at: url, type: .jpeg, properties: [kCGImagePropertyTIFFDictionary: tiff])

        #expect(Self.metadataString(at: url, path: "xmp:ModifyDate") != nil)
        #expect(try ImageDateWriter.embeddedDate(at: url) == nil)
        try ImageDateWriter.write(Self.fixtureDate, to: url)

        #expect(Self.exifDateTimeOriginal(at: url) == "2026:08:30 12:34:56")
        let readBack = try #require(try ImageDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(Self.fixtureDate)) < 1)
    }

    @Test
    func `A file that is not an image throws instead of trapping`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake.jpg")
        try Data("not an image".utf8).write(to: url)

        #expect(throws: DateFixError.self) { try ImageDateWriter.embeddedDate(at: url) }
        #expect(throws: DateFixError.self) { try ImageDateWriter.write(Self.fixtureDate, to: url) }
        #expect(try Data(contentsOf: url) == Data("not an image".utf8))
    }

    // MARK: - Fixtures

    /// 2026-08-30 12:34:56 in the current zone, which is what the EXIF strings are written in.
    static var fixtureDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 12, minute: 34, second: 56)) ?? Date()
    }

    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-dates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A 16×16 gradient so the encoded bitstream is not trivially empty.
    static func makeImage() throws -> CGImage {
        let size = 16
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw MTPError.malformedData("could not create a bitmap context")
        }
        for row in 0 ..< size {
            context.setFillColor(red: CGFloat(row) / CGFloat(size), green: 0.5, blue: 1 - CGFloat(row) / CGFloat(size), alpha: 1)
            context.fill(CGRect(x: 0, y: row, width: size, height: 1))
        }
        guard let image = context.makeImage() else {
            throw MTPError.malformedData("could not render the fixture image")
        }
        return image
    }

    static func writeFixture(at url: URL, type: UTType, properties: [CFString: Any]? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw MTPError.malformedData("could not create a destination for \(type.identifier)")
        }
        try CGImageDestinationAddImage(destination, makeImage(), properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else {
            throw MTPError.malformedData("could not finalize \(url.lastPathComponent)")
        }
    }

    static func pixelBytes(at url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data
        else {
            throw MTPError.malformedData("could not decode \(url.lastPathComponent)")
        }
        return data as Data
    }

    static func exifDateTimeOriginal(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    static func metadataString(at url: URL, path: String) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }
}
