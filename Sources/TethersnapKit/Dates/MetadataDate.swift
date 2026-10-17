import Foundation

/// The date strings image and video metadata carry, parsed and rendered without
/// `DateFormatter` (not `Sendable`, and the EXIF offset tag needs a per-call zone).
/// Also the one place that turns validated calendar fields into a `Date`, shared
/// by the PTP and filename parsers.
enum MetadataDate {
    /// EXIF `yyyy:MM:dd HH:mm:ss` and ISO 8601 `yyyy-MM-dd'T'HH:mm:ss`, optional
    /// fractional seconds, optional `Z` / `+08:00` / `+0800`. Built once;
    /// `nonisolated(unsafe)` because a `Regex` is immutable but not annotated `Sendable`.
    private nonisolated(unsafe) static let pattern = /^\s*(\d{4})[-:](\d{2})[-:](\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?\s*$/

    /// Parses the EXIF and ISO 8601 forms above. A string without a zone is
    /// read in `zone`.
    static func parse(_ string: String, assuming zone: TimeZone = .current) -> Date? {
        guard let match = string.wholeMatch(of: pattern),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6)
        else { return nil }
        let timeZone = match.7.flatMap { offsetZone(String($0)) } ?? zone
        return date(year: year, month: month, day: day, hour: hour, minute: minute, second: second, zone: timeZone)
    }

    /// A Gregorian date from calendar fields, nil when they do not name a real
    /// instant (month 13, February 30, hour 25). `Calendar.date(from:)` alone
    /// would roll such values forward instead of refusing them.
    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            calendar: calendar, timeZone: zone,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// `+08:00`, `+0800`, or `Z` as a fixed-offset zone.
    static func offsetZone(_ string: String) -> TimeZone? {
        if string == "Z" { return TimeZone(secondsFromGMT: 0) }
        let digits = string.dropFirst().filter(\.isNumber)
        guard string.count >= 5, digits.count == 4,
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 23, minutes <= 59
        else { return nil }
        let sign = string.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    /// EXIF `yyyy:MM:dd HH:mm:ss` in `zone`.
    static func exifString(_ date: Date, in zone: TimeZone = .current) -> String {
        let parts = components(of: date, in: zone)
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
    }

    /// ISO 8601 `yyyy-MM-dd'T'HH:mm:ss` followed by the offset, `+08:00` with a colon or
    /// `+0800` without (the QuickTime creation-date form).
    static func isoString(_ date: Date, in zone: TimeZone = .current, offsetColon: Bool) -> String {
        let parts = components(of: date, in: zone)
        let clock = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
        return clock + offsetString(for: date, in: zone, colon: offsetColon)
    }

    /// `+08:00` (or `+0800` without the colon) for `zone` at `date`.
    static func offsetString(for date: Date, in zone: TimeZone = .current, colon: Bool) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        return String(format: colon ? "%@%02d:%02d" : "%@%02d%02d", seconds < 0 ? "-" : "+", hours, minutes)
    }

    private struct Parts {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
    }

    private static func components(of date: Date, in zone: TimeZone) -> Parts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return Parts(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0,
            hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0
        )
    }
}
