import Foundation

/// Parses PTP DateTime strings ("YYYYMMDDThhmmss", optional ".s" tenth and
/// optional "Z" / "±hhmm" zone). Filename timestamps are ``FilenameDate``'s job.
public enum PTPDateParser {
    public static func parse(_ string: String) -> Date? {
        guard string.count >= 15 else { return nil }
        let chars = Array(string)
        guard chars[8] == "T" else { return nil }
        guard let year = int(chars, 0, 4), let month = int(chars, 4, 2), let day = int(chars, 6, 2),
              let hour = int(chars, 9, 2), let minute = int(chars, 11, 2), let second = int(chars, 13, 2)
        else { return nil }

        var index = 15
        if index < chars.count, chars[index] == "." { index += 2 } // skip tenths
        // No zone means the responder's local time, read as this Mac's.
        let timeZone = index < chars.count ? MetadataDate.offsetZone(String(chars[index...])) ?? .current : .current
        return MetadataDate.date(year: year, month: month, day: day, hour: hour, minute: minute, second: second, zone: timeZone)
    }

    /// Exactly `count` ASCII digits at `start`; a sign or a shorter run is rejected.
    private static func int(_ chars: [Character], _ start: Int, _ count: Int) -> Int? {
        guard start + count <= chars.count else { return nil }
        let run = chars[start ..< start + count]
        guard run.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(String(run))
    }
}
