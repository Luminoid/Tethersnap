import Foundation
import Testing
@testable import TethersnapKit

@Suite("Filename dates")
struct FilenameDateTests {
    /// A filename and the local-time components it should yield.
    struct Expectation: Sendable, CustomTestStringConvertible {
        let filename: String
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int

        init(_ filename: String, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) {
            self.filename = filename
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
        }

        var testDescription: String { filename }
    }

    static let accepted: [Expectation] = [
        // Switch 2
        Expectation("2026083012345600-02CB906EA538A35643C1E1484C4B947D.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("2026083012345601-02CB906EA538A35643C1E1484C4B947D.mp4", 2026, 8, 30, 12, 34, 56),
        Expectation("2026010109300000-BEEF.mp4", 2026, 1, 1, 9, 30, 0),
        // Original Switch over USB (Copy to PC)
        Expectation("2026083012345600_s.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("2026083012345701_s.mp4", 2026, 8, 30, 12, 34, 57),
        // Compact fourteen digits
        Expectation("Astro's Playroom_20260830123456.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("20260830123456_1.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("20260830_123456.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("IMG_20260830_123456.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("PXL_20260830_123456789.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("Game_20260830123456.webm", 2026, 8, 30, 12, 34, 56),
        // Hyphenated
        Expectation("Screenshot 2026-08-30 at 12.34.56 PM.png", 2026, 8, 30, 12, 34, 56),
        Expectation("Screenshot 2026-08-30 at 12.34.56 AM.png", 2026, 8, 30, 0, 34, 56),
        Expectation("Screenshot 2026-08-30 at 1.34.56 PM.png", 2026, 8, 30, 13, 34, 56),
        Expectation("Screenshot 2026-08-30 at 9.05.07 AM.png", 2026, 8, 30, 9, 5, 7),
        Expectation("Screenshot 2026-08-30 at 12.34.56.png", 2026, 8, 30, 12, 34, 56),
        Expectation("Screenshot 2026-08-30 at 23.59.59.png", 2026, 8, 30, 23, 59, 59),
        Expectation("2026-08-30 12.34.56.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("2026-08-30_12-34-56.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("2026-08-30T123456.jpg", 2026, 8, 30, 12, 34, 56),
        Expectation("2026-08-30 12:34:56.jpg", 2026, 8, 30, 12, 34, 56),
    ]

    static let rejected: [String] = [
        "IMG_1234.jpg",
        "20261330123456_1.jpg", // month 13
        "19890830123456_1.jpg", // year 1989
        "2026-02-30_12-00-00.jpg", // February 30
        "2026-08-30.png", // date only
        "IMG_2026083012345.jpg", // thirteen digits
        "202608301234567.jpg", // fifteen digits
        "2026083012345600.jpg", // sixteen digits with neither Switch suffix
        "02CB906EA538A35643C1E1484C4B947D.jpg", // hex title id without a timestamp prefix
        "Screenshot 2026-08-30 at 13.34.56 PM.png", // 13 PM
        "Screenshot 2026-08-30 at 0.34.56 AM.png", // 0 AM
        "notes.txt",
        "",
    ]

    /// The parse zone is pinned so the expectations hold on any machine.
    private static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }

    @Test(arguments: accepted)
    func `Parses the timestamp a capture filename carries`(expectation: Expectation) throws {
        let calendar = Self.shanghai
        let date = try #require(FilenameDate.parse(expectation.filename, calendar: calendar))

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == expectation.year)
        #expect(parts.month == expectation.month)
        #expect(parts.day == expectation.day)
        #expect(parts.hour == expectation.hour)
        #expect(parts.minute == expectation.minute)
        #expect(parts.second == expectation.second)
    }

    @Test(arguments: rejected)
    func `Rejects names without a plausible timestamp`(filename: String) {
        #expect(FilenameDate.parse(filename, calendar: Self.shanghai) == nil)
    }

    @Test
    func `The digits are read in the calendar's time zone`() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt

        let shanghai = try #require(FilenameDate.parse("IMG_20260830_123456.jpg", calendar: Self.shanghai))
        let greenwich = try #require(FilenameDate.parse("IMG_20260830_123456.jpg", calendar: utc))

        // Shanghai is UTC+8, so the same wall-clock digits are eight hours earlier as an instant.
        #expect(greenwich.timeIntervalSince(shanghai) == 8 * 3600)
    }

    @Test
    func `The Switch pattern wins over the compact one for the same digits`() throws {
        // Both patterns match a Switch name; the first match decides, and both agree.
        let name = "2026083012345600-02CB906EA538A35643C1E1484C4B947D.jpg"
        let date = try #require(FilenameDate.parse(name, calendar: Self.shanghai))
        let parts = Self.shanghai.dateComponents([.hour, .second], from: date)

        #expect(parts.hour == 12)
        #expect(parts.second == 56)
    }
}
