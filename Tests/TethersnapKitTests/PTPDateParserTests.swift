import Foundation
import Testing
@testable import TethersnapKit

@Suite("PTP date parsing")
struct PTPDateParserTests {
    @Test
    func `Parses the plain PTP DateTime form in local time`() throws {
        let date = try #require(PTPDateParser.parse("20260829T142530"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 29)
        #expect(components.hour == 14)
        #expect(components.minute == 25)
        #expect(components.second == 30)
    }

    @Test
    func `Honors tenths and UTC / offset zone suffixes`() throws {
        let utc = try #require(PTPDateParser.parse("20260101T000000.0Z"))
        let offset = try #require(PTPDateParser.parse("20260101T080000+0800"))

        #expect(utc == offset)
    }

    @Test
    func `Rejects garbage instead of producing a date`() {
        #expect(PTPDateParser.parse("not a date") == nil)
        #expect(PTPDateParser.parse("20260829142530") == nil) // missing T
        #expect(PTPDateParser.parse("+026-829T14:25:3") == nil) // signs where digits belong
    }

    @Test
    func `Impossible fields are refused instead of rolling into the next month`() {
        // Calendar.date(from:) alone would turn February 30 into March 2.
        #expect(PTPDateParser.parse("20260230T120000") == nil)
        #expect(PTPDateParser.parse("20261301T120000") == nil)
        #expect(PTPDateParser.parse("20260829T250000") == nil)
        #expect(PTPDateParser.parse("20260228T235959") != nil)
    }
}
