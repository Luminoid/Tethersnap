import Foundation

/// The non-real-time record Sony cameras write for every XAVC clip, as
/// `C0001M01.XML` beside `C0001.MP4` and again inside the clip as a top-level
/// `meta/xml` box: the exact start time with its zone, the camera, and the
/// position when the camera had a fix (its own GPS or a linked phone).
public struct SonyClipMetadata: Sendable, Equatable {
    public struct Location: Sendable, Equatable {
        /// Signed decimal degrees.
        public let latitude: Double
        public let longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public let creationDate: Date
    public let timeZone: TimeZone
    public let manufacturer: String?
    public let model: String?
    public let location: Location?

    public var hasCamera: Bool {
        manufacturer != nil || model != nil
    }

    /// The record for the clip at `url`: the copy inside the file first, then
    /// the sidecar beside it; nil when neither exists or parses.
    public static func read(for url: URL) -> Self? {
        if let xml = try? MovieMetadataPatcher.embeddedXML(at: url), let record = parse(xml) {
            return record
        }
        guard let sidecar = sidecarURL(for: url), let xml = try? Data(contentsOf: sidecar) else { return nil }
        return parse(xml)
    }

    /// `C0001M01.XML` beside `C0001.MP4`, when it exists.
    static func sidecarURL(for url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        for name in ["\(stem)M01.XML", "\(stem)M01.xml"] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// True for a sidecar's own filename; the fixer consumes those through
    /// their clip instead of listing them.
    public static func isSidecarName(_ filename: String) -> Bool {
        filename.count > 7 && filename.uppercased().hasSuffix("M01.XML")
    }

    /// Parses a NonRealTimeMeta document; anything else, or one without a
    /// creation date, is nil.
    static func parse(_ xml: Data) -> Self? {
        let record = RecordParser()
        let parser = XMLParser(data: xml)
        parser.delegate = record
        parser.parse()
        guard record.isRecord, let value = record.creationDate, let date = MetadataDate.parse(value) else { return nil }
        let zone = value.firstMatch(of: offsetPattern).flatMap { MetadataDate.offsetZone(String($0.1)) } ?? .current
        return Self(
            creationDate: date, timeZone: zone, manufacturer: nonEmpty(record.manufacturer), model: nonEmpty(record.model),
            location: location(from: record.gps)
        )
    }

    /// The `ExifGPS` group as EXIF writes it: `37:24:56.169` with an `N`/`S`
    /// or `E`/`W` reference; `Status` `V` means the receiver had no fix.
    static func location(from gps: [String: String]) -> Location? {
        guard gps["Status"] != "V",
              let latitude = degrees(gps["Latitude"], negativeWhen: gps["LatitudeRef"] == "S"),
              let longitude = degrees(gps["Longitude"], negativeWhen: gps["LongitudeRef"] == "W"),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return Location(latitude: latitude, longitude: longitude)
    }

    private static func degrees(_ value: String?, negativeWhen negative: Bool) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let degrees = parts[0], let minutes = parts[1], let seconds = parts[2] else { return nil }
        let magnitude = degrees + minutes / 60 + seconds / 3600
        return negative ? -magnitude : magnitude
    }

    private nonisolated(unsafe) static let offsetPattern = /(Z|[+-]\d{2}:?\d{2})\s*$/

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        return string
    }

    /// Collects the three attributes the record is read for.
    private final nonisolated class RecordParser: NSObject, XMLParserDelegate {
        var isRecord = false
        var creationDate: String?
        var manufacturer: String?
        var model: String?
        var gps: [String: String] = [:]
        private var depth = 0
        private var group: String?

        func parser(_: XMLParser, didStartElement element: String, namespaceURI _: String?, qualifiedName _: String?, attributes: [String: String] = [:]) {
            depth += 1
            if depth == 1 {
                isRecord = element == "NonRealTimeMeta"
                return
            }
            switch element {
            case "CreationDate":
                creationDate = attributes["value"]
            case "Device":
                manufacturer = attributes["manufacturer"]
                model = attributes["modelName"]
            case "Group":
                group = attributes["name"]
            case "Item" where group == "ExifGPS":
                if let name = attributes["name"], let value = attributes["value"] {
                    gps[name] = value
                }
            default:
                break
            }
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            depth -= 1
            if element == "Group" {
                group = nil
            }
        }
    }
}
