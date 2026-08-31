import Foundation

/// Parses PTP DateTime strings ("YYYYMMDDThhmmss", optional ".s" tenth and
/// optional "Z" / "±hhmm" zone) and Switch capture-filename timestamps.
public enum PTPDateParser {
    public static func parse(_ string: String) -> Date? {
        guard string.count >= 15 else { return nil }
        let chars = Array(string)
        guard chars[8] == "T" else { return nil }
        guard let year = int(chars, 0, 4), let month = int(chars, 4, 2), let day = int(chars, 6, 2),
              let hour = int(chars, 9, 2), let minute = int(chars, 11, 2), let second = int(chars, 13, 2)
        else { return nil }

        var timeZone = TimeZone.current
        var index = 15
        if index < chars.count, chars[index] == "." { index += 2 } // skip tenths
        if index < chars.count {
            if chars[index] == "Z" {
                timeZone = TimeZone(identifier: "UTC") ?? .current
            } else if chars[index] == "+" || chars[index] == "-",
                      let zoneHour = int(chars, index + 1, 2) {
                let zoneMinute = int(chars, index + 3, 2) ?? 0
                let sign = chars[index] == "-" ? -1 : 1
                timeZone = TimeZone(secondsFromGMT: sign * (zoneHour * 3600 + zoneMinute * 60)) ?? .current
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    /// Switch capture filenames start with "YYYYMMDDhhmmssXX-<title id>".
    public static func parseFilenameTimestamp(_ filename: String) -> Date? {
        let digits = filename.prefix(while: \.isNumber)
        guard digits.count >= 14 else { return nil }
        let stamp = Array(digits.prefix(14))
        return parse(String(stamp[0 ..< 8]) + "T" + String(stamp[8 ..< 14]))
    }

    private static func int(_ chars: [Character], _ start: Int, _ count: Int) -> Int? {
        guard start + count <= chars.count else { return nil }
        return Int(String(chars[start ..< start + count]))
    }
}
