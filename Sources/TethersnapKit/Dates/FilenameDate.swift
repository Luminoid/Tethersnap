import Foundation

/// Recovers the local-time timestamp a capture filename carries.
///
/// Consoles, phones, and desktop screenshot tools all stamp the shot time into the
/// filename, so a file whose metadata was stripped (or never written) still tells
/// when it was taken. Patterns are tried in order and the first match wins; nothing
/// plausible yields nil.
public enum FilenameDate {
    /// Parses `filename`, interpreting the digits in `calendar`'s time zone
    /// (the zone is the only part of `calendar` used; the date is built with a
    /// Gregorian calendar).
    public static func parse(_ filename: String, calendar: Calendar = .current) -> Date? {
        for pattern in patterns {
            guard let stamp = pattern(filename) else { continue }
            return date(from: stamp, timeZone: calendar.timeZone)
        }
        return nil
    }

    // MARK: - Patterns

    /// The digits a pattern captured, before validation.
    private struct Stamp {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        /// `AM` / `PM` when the filename used a 12-hour clock.
        var meridiem: Substring?
    }

    /// Ordered matchers; the first one to match decides.
    private static let patterns: [@Sendable (String) -> Stamp?] = [matchSwitch, matchCompact, matchHyphenated]

    // The regexes are built once: `parse` runs for every enumerated file and
    // as the PTP date fallback, and a literal rebuilds its program per call.
    // `nonisolated(unsafe)`: a built `Regex` is immutable and matching never
    // mutates it; the type merely lacks the `Sendable` annotation.

    /// Switch album names: a timestamp and a two-digit sequence number, then
    /// the hex title id on an SD card or a Switch 2
    /// (`2026083012345600-02CB906EA538A35643C1E1484C4B947D.jpg`), or a letter
    /// suffix on the original Switch's USB export (`2026083012345600_s.jpg`).
    private nonisolated(unsafe) static let switchPattern = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\d{2}(?:-[0-9A-Fa-f]+|_[A-Za-z]+)\./

    /// Fourteen compact digits, optionally split by `_`, optionally followed by three
    /// millisecond digits: PS4/PS5 `Astro's Playroom_20260830123456.jpg`, Steam
    /// `20260830123456_1.jpg`, Samsung `20260830_123456.jpg`, Android
    /// `IMG_20260830_123456.jpg`, Pixel `PXL_20260830_123456789.jpg`.
    /// Swift Regex has no lookbehind, so a run is bounded by `(?:^|\D)` and `(?!\d)`.
    private nonisolated(unsafe) static let compactPattern = /(?:^|\D)(\d{4})(\d{2})(\d{2})_?(\d{2})(\d{2})(\d{2})(?:\d{3})?(?!\d)/

    /// Hyphenated date plus a separated time: macOS `Screenshot 2026-08-30 at 12.34.56 PM.png`
    /// (single-digit hours too: `at 9.41.00 AM`), `2026-08-30 12.34.56.jpg`,
    /// `2026-08-30_12-34-56.jpg`, `2026-08-30T123456.jpg`.
    private nonisolated(unsafe) static let hyphenatedPattern = /(\d{4})-(\d{2})-(\d{2})(?: at |[ T_])(\d{1,2})[.:\-]?(\d{2})[.:\-]?(\d{2})(?: ?([AP]M))?(?!\d)/

    private static func matchSwitch(_ filename: String) -> Stamp? {
        guard let match = filename.firstMatch(of: switchPattern) else { return nil }
        return stamp(match.1, match.2, match.3, match.4, match.5, match.6)
    }

    private static func matchCompact(_ filename: String) -> Stamp? {
        guard let match = filename.firstMatch(of: compactPattern) else { return nil }
        return stamp(match.1, match.2, match.3, match.4, match.5, match.6)
    }

    private static func matchHyphenated(_ filename: String) -> Stamp? {
        guard let match = filename.firstMatch(of: hyphenatedPattern) else { return nil }
        guard var result = stamp(match.1, match.2, match.3, match.4, match.5, match.6) else { return nil }
        result.meridiem = match.7
        return result
    }

    private static func stamp(_ year: Substring, _ month: Substring, _ day: Substring, _ hour: Substring, _ minute: Substring, _ second: Substring) -> Stamp? {
        guard let year = Int(year), let month = Int(month), let day = Int(day),
              let hour = Int(hour), let minute = Int(minute), let second = Int(second)
        else { return nil }
        return Stamp(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    // MARK: - Validation

    private static func date(from stamp: Stamp, timeZone: TimeZone) -> Date? {
        var hour = stamp.hour
        if let meridiem = stamp.meridiem {
            // 12-hour clock: 12 AM is midnight, 12 PM is noon.
            guard (1 ... 12).contains(hour) else { return nil }
            hour %= 12
            if meridiem == "PM" { hour += 12 }
        }
        // The year window rejects digit runs that are not dates at all (a 32-hex
        // title id, a serial number); `MetadataDate.date` rejects February 30.
        guard (1990 ... 2099).contains(stamp.year) else { return nil }
        return MetadataDate.date(
            year: stamp.year, month: stamp.month, day: stamp.day, hour: hour, minute: stamp.minute, second: stamp.second, zone: timeZone
        )
    }
}
