import Foundation
import Testing
@testable import TethersnapKit

@Suite("Metadata dates")
struct MetadataDateTests {
    private static let utc = TimeZone.gmt
    private static let plusEight = TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt

    @Test
    func `EXIF and ISO 8601 forms parse to the same instant`() throws {
        let exif = try #require(MetadataDate.parse("2026:08:30 12:34:56", assuming: Self.plusEight))
        let iso = try #require(MetadataDate.parse("2026-08-30T12:34:56+08:00"))
        let compact = try #require(MetadataDate.parse("2026-08-30T12:34:56+0800"))
        let zulu = try #require(MetadataDate.parse("2026-08-30T04:34:56Z"))
        let fractional = try #require(MetadataDate.parse("2026-08-30T04:34:56.250Z"))

        #expect(exif == iso)
        #expect(iso == compact)
        #expect(iso == zulu)
        #expect(abs(fractional.timeIntervalSince(zulu)) < 1)
    }

    @Test
    func `Impossible calendar fields are refused, not rolled forward`() {
        #expect(MetadataDate.parse("2026:02:30 12:00:00") == nil)
        #expect(MetadataDate.parse("2026:13:01 12:00:00") == nil)
        #expect(MetadataDate.parse("2026:08:30 25:00:00") == nil)
        #expect(MetadataDate.date(year: 2026, month: 2, day: 30, hour: 0, minute: 0, second: 0, zone: Self.utc) == nil)
        #expect(MetadataDate.date(year: 2026, month: 2, day: 28, hour: 0, minute: 0, second: 0, zone: Self.utc) != nil)
        #expect(MetadataDate.parse("yesterday") == nil)
    }

    @Test
    func `Offset suffixes map to fixed zones and malformed ones to nil`() {
        #expect(MetadataDate.offsetZone("Z")?.secondsFromGMT() == 0)
        #expect(MetadataDate.offsetZone("+08:00")?.secondsFromGMT() == 8 * 3600)
        #expect(MetadataDate.offsetZone("+0800")?.secondsFromGMT() == 8 * 3600)
        #expect(MetadataDate.offsetZone("-05:30")?.secondsFromGMT() == -(5 * 3600 + 30 * 60))
        #expect(MetadataDate.offsetZone("+08") == nil)
        #expect(MetadataDate.offsetZone("+25:00") == nil)
        #expect(MetadataDate.offsetZone("") == nil)
    }

    @Test
    func `Rendered strings round-trip through the parser`() throws {
        let date = try #require(MetadataDate.date(year: 2026, month: 8, day: 30, hour: 12, minute: 34, second: 56, zone: Self.plusEight))

        #expect(MetadataDate.exifString(date, in: Self.plusEight) == "2026:08:30 12:34:56")
        #expect(MetadataDate.isoString(date, in: Self.plusEight, offsetColon: true) == "2026-08-30T12:34:56+08:00")
        #expect(MetadataDate.isoString(date, in: Self.plusEight, offsetColon: false) == "2026-08-30T12:34:56+0800")
        #expect(MetadataDate.offsetString(for: date, in: Self.utc, colon: true) == "+00:00")
        #expect(MetadataDate.parse(MetadataDate.isoString(date, in: Self.plusEight, offsetColon: false)) == date)
    }
}
