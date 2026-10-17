import Foundation

/// Lossless, in-place metadata for MP4, M4V, and QuickTime movies: the header
/// times and the `com.apple.quicktime.*` keys Apple's readers use, written by
/// rewriting the `moov` box alone. Samples, tracks, and vendor boxes stay byte
/// for byte where they are, so nothing a re-mux would drop (timecode tracks,
/// a camera's per-track and clip records) is lost.
enum MovieMetadataPatcher {
    struct Metadata: Sendable {
        var creationDate: Date
        /// The zone the `creationdate` key is rendered in; header times are UTC.
        var timeZone: TimeZone
        var make: String?
        var model: String?
        var location: SonyClipMetadata.Location?
    }

    static let creationDateKey = "com.apple.quicktime.creationdate"
    static let makeKey = "com.apple.quicktime.make"
    static let modelKey = "com.apple.quicktime.model"
    static let locationKey = "com.apple.quicktime.location.ISO6709"

    /// Why a file could not be patched; every case surfaces as `DateFixError.videoContainerUnsupported`.
    enum Failure: Error {
        case malformed
        case noMovieBox
        case tooLarge
        case foreignMetadata
    }

    /// Boxes that may follow `moov` without any sample offset depending on
    /// them, so the tail can be rewritten in place.
    private static let offsetFreeTypes: Set<String> = ["free", "skip", "meta", "uuid", "wide"]
    private static let mdtaNamespace = Data("mdta".utf8)
    /// A two-hour clip's sample tables are a few megabytes; anything near this is not a `moov`.
    private static let maxMoovSize: UInt64 = 512 << 20
    private static let maxTailSize: UInt64 = 64 << 20
    /// Seconds from the QuickTime epoch (1904-01-01) to the Unix epoch.
    private static let epochOffset: TimeInterval = 2_082_844_800

    // MARK: - Boxes

    /// A box header as laid out in a file or a `Data` (offsets from its start).
    struct Box: Equatable {
        /// The raw four bytes: `ilst` children carry an index here, not ASCII.
        let typeBytes: Data
        let offset: UInt64
        let headerSize: UInt64
        /// The whole box, header included.
        let size: UInt64

        /// Latin-1 never fails, and the ASCII types this code compares against survive it.
        var type: String { String(bytes: typeBytes, encoding: .isoLatin1) ?? "" }
        var payloadOffset: UInt64 { offset + headerSize }
        var payloadSize: UInt64 { size - headerSize }
        var end: UInt64 { offset + size }
    }

    /// The top-level boxes of the file behind `handle`.
    static func topLevelBoxes(in handle: FileHandle) throws -> [Box] {
        let end = try handle.seekToEnd()
        return try boxes(from: 0, to: end) { offset, count in try read(handle, offset, UInt64(count)) }
    }

    /// The boxes laid end to end in `data[range]` (offsets from `data`'s start).
    static func boxes(in data: Data, range: Range<UInt64>? = nil) throws -> [Box] {
        let range = range ?? 0 ..< UInt64(data.count)
        return try boxes(from: range.lowerBound, to: range.upperBound) { offset, count in
            slice(data, offset, UInt64(count))
        }
    }

    /// `type` must be four ASCII characters; the size is 32-bit, or 64-bit past 4 GiB.
    static func box(_ type: String, _ payload: Data) -> Data {
        box(typeBytes: Data(type.utf8), payload)
    }

    static func box(typeBytes: Data, _ payload: Data) -> Data {
        var data = Data()
        let total = UInt64(payload.count) + 8
        if total <= UInt64(UInt32.max) {
            data.append(bigEndian(UInt32(total)))
            data.append(typeBytes)
        } else {
            data.append(bigEndian(UInt32(1)))
            data.append(typeBytes)
            data.append(bigEndian(total + 8))
        }
        data.append(payload)
        return data
    }

    private static func boxes(from start: UInt64, to end: UInt64, read: (UInt64, Int) throws -> Data) throws -> [Box] {
        var result: [Box] = []
        var position = start
        while position < end {
            let header = try read(position, 8)
            guard header.count == 8 else { throw Failure.malformed }
            var size = UInt64(header.bigEndianUInt32(at: 0))
            var headerSize: UInt64 = 8
            if size == 1 {
                let large = try read(position + 8, 8)
                guard large.count == 8 else { throw Failure.malformed }
                size = large.bigEndianUInt64(at: 0)
                headerSize = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerSize, position + size <= end else { throw Failure.malformed }
            result.append(Box(typeBytes: Data(header[4 ..< 8]), offset: position, headerSize: headerSize, size: size))
            position += size
        }
        return result
    }

    // MARK: - Reading

    /// The document inside a top-level `meta/xml` box (Sony clips embed their
    /// non-real-time record there), nil when the file has none.
    static func embeddedXML(at url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for meta in try topLevelBoxes(in: handle) where meta.type == "meta" {
            guard meta.payloadSize <= maxTailSize else { continue }
            let payload = try read(handle, meta.payloadOffset, meta.payloadSize)
            guard let (_, children) = try? metaChildren(of: payload),
                  let xml = children.first(where: { $0.type == "xml " }), xml.payloadSize > 4 else { continue }
            // A full box: version and flags precede the document.
            let document = slice(payload, xml.payloadOffset + 4, xml.payloadSize - 4)
            return Data(document.reversed().drop { $0 == 0 }.reversed())
        }
        return nil
    }

    /// The mdta keys and UTF-8 values of a `moov` payload's `meta` box.
    static func metadataKeys(ofMoovPayload payload: Data) throws -> [String: String] {
        guard let meta = try boxes(in: payload).first(where: { $0.type == "meta" }) else { return [:] }
        let parsed = try parseMeta(slice(payload, meta.payloadOffset, meta.payloadSize))
        var result: [String: String] = [:]
        for (index, key) in parsed.keys.enumerated() where key.namespace == mdtaNamespace {
            let entry = parsed.entries[index]
            guard let data = try? boxes(in: entry).first(where: { $0.type == "data" }), data.payloadSize > 8,
                  let name = String(bytes: key.name, encoding: .utf8),
                  let value = String(bytes: slice(entry, data.payloadOffset + 8, data.payloadSize - 8), encoding: .utf8) else { continue }
            result[name] = value
        }
        return result
    }

    // MARK: - Writing

    /// Rewrites the movie at `url` with `metadata`, through a sibling temp file
    /// that starts as a copy (a clone on APFS). A file whose structure is not
    /// understood is left untouched and reported as unsupported.
    static func patch(_ url: URL, with metadata: Metadata) throws {
        do {
            try AtomicRewrite.replace(url) { temp in
                try FileManager.default.copyItem(at: url, to: temp)
                let handle = try FileHandle(forUpdating: temp)
                defer { try? handle.close() }
                try rewrite(handle, with: metadata)
                try handle.synchronize()
            }
        } catch let failure as Failure {
            TethersnapLog.warning(.dates, "movie structure cannot be patched (\(failure))", private: url.path)
            throw DateFixError.videoContainerUnsupported(url.lastPathComponent)
        }
    }

    private static func rewrite(_ handle: FileHandle, with metadata: Metadata) throws {
        let boxes = try topLevelBoxes(in: handle)
        let moovs = boxes.filter { $0.type == "moov" }
        guard moovs.count == 1, let moov = moovs.first else { throw Failure.noMovieBox }
        guard moov.payloadSize <= maxMoovSize else { throw Failure.tooLarge }
        let payload = try read(handle, moov.payloadOffset, moov.payloadSize)
        let newMoov = try box("moov", patchedMoovPayload(payload, with: metadata))
        let tail = boxes.filter { $0.offset > moov.offset }
        let tailSize = tail.reduce(UInt64(0)) { $0 + $1.size }
        if tail.allSatisfy({ offsetFreeTypes.contains($0.type) }), tailSize <= maxTailSize {
            // Nothing after the old moov is addressed by offset: rewrite the tail.
            let tailBytes = tailSize > 0 ? try read(handle, moov.end, tailSize) : Data()
            try handle.truncate(atOffset: moov.offset)
            try handle.seek(toOffset: moov.offset)
            try handle.write(contentsOf: newMoov)
            try handle.write(contentsOf: tailBytes)
        } else {
            // Samples follow the old moov, so it stays where it is as free space
            // (same size, so no chunk offset moves) and the new one goes last.
            try handle.seek(toOffset: moov.offset + 4)
            try handle.write(contentsOf: Data("free".utf8))
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: newMoov)
        }
    }

    /// The moov payload with its header times stamped and its `meta` box
    /// merged with `metadata`'s keys (appended last when there was none).
    static func patchedMoovPayload(_ payload: Data, with metadata: Metadata) throws -> Data {
        var data = payload
        let seconds = quickTimeSeconds(metadata.creationDate)
        var existingMeta: Box?
        for child in try boxes(in: data) {
            switch child.type {
            case "mvhd":
                try stampTimes(&data, in: child, seconds)
            case "trak":
                try stampTrack(&data, trak: child, seconds)
            case "meta":
                existingMeta = child
            default:
                break
            }
        }
        var values = [(creationDateKey, MetadataDate.isoString(metadata.creationDate, in: metadata.timeZone, offsetColon: false))]
        if let make = metadata.make, !make.isEmpty { values.append((makeKey, make)) }
        if let model = metadata.model, !model.isEmpty { values.append((modelKey, model)) }
        if let location = metadata.location { values.append((locationKey, iso6709(location))) }
        let meta = try metaBox(merging: existingMeta.map { slice(data, $0.payloadOffset, $0.payloadSize) }, with: values)
        if let existingMeta {
            data.removeSubrange(Int(existingMeta.offset) ..< Int(existingMeta.end))
        }
        data.append(meta)
        return data
    }

    /// `+37.4156-121.9579/`, the ISO 6709 form Photos and the Finder read
    /// (iPhone clips add an altitude; a record carries none).
    static func iso6709(_ location: SonyClipMetadata.Location) -> String {
        String(format: "%+08.4f%+09.4f/", location.latitude, location.longitude)
    }

    /// Seconds since 1904-01-01 UTC, the unit of every movie header time.
    static func quickTimeSeconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 + epochOffset).rounded())
    }

    /// Creation and modification time of an `mvhd`, `tkhd`, or `mdhd` payload:
    /// 32-bit fields in version 0, 64-bit in version 1, right after version and flags.
    private static func stampTimes(_ data: inout Data, in box: Box, _ seconds: UInt64) throws {
        let start = Int(box.payloadOffset)
        guard box.payloadSize >= 4, start < data.count else { throw Failure.malformed }
        if data[data.startIndex + start] == 1 {
            guard box.payloadSize >= 20 else { throw Failure.malformed }
            data.replaceSubrange(start + 4 ..< start + 20, with: bigEndian(seconds) + bigEndian(seconds))
        } else {
            guard box.payloadSize >= 12 else { throw Failure.malformed }
            let value = bigEndian(UInt32(min(seconds, UInt64(UInt32.max))))
            data.replaceSubrange(start + 4 ..< start + 12, with: value + value)
        }
    }

    private static func stampTrack(_ data: inout Data, trak: Box, _ seconds: UInt64) throws {
        for child in try boxes(in: data, range: trak.payloadOffset ..< trak.end) {
            switch child.type {
            case "tkhd":
                try stampTimes(&data, in: child, seconds)
            case "mdia":
                for grandchild in try boxes(in: data, range: child.payloadOffset ..< child.end) where grandchild.type == "mdhd" {
                    try stampTimes(&data, in: grandchild, seconds)
                }
            default:
                break
            }
        }
    }

    // MARK: - meta

    private struct ParsedMeta {
        var isFullBox = false
        var keys: [(namespace: Data, name: Data)] = []
        /// The `ilst` child payload (its `data` boxes) per key, same order as `keys`.
        var entries: [Data] = []
        /// Children other than `hdlr`, `keys`, and `ilst`, kept verbatim.
        var others: [Data] = []
    }

    /// QuickTime's `meta` has no version and flags, ISO's does: the first child
    /// box (always `hdlr`) starts at 0 or at 4.
    private static func metaChildren(of payload: Data) throws -> (isFullBox: Bool, children: [Box]) {
        if payload.count >= 8, slice(payload, 4, 4) == Data("hdlr".utf8) {
            return try (false, boxes(in: payload))
        }
        if payload.count >= 12, slice(payload, 8, 4) == Data("hdlr".utf8) {
            return try (true, boxes(in: payload, range: 4 ..< UInt64(payload.count)))
        }
        throw Failure.foreignMetadata
    }

    private static func parseMeta(_ payload: Data) throws -> ParsedMeta {
        let (isFullBox, children) = try metaChildren(of: payload)
        var parsed = ParsedMeta(isFullBox: isFullBox)
        var entriesByIndex: [UInt32: Data] = [:]
        for child in children {
            let body = slice(payload, child.payloadOffset, child.payloadSize)
            switch child.type {
            case "hdlr":
                // Only the mdta handler's keys and values are understood; any
                // other kind of metadata box is left alone rather than guessed at.
                guard body.count >= 12, Data(body[8 ..< 12]) == mdtaNamespace else { throw Failure.foreignMetadata }
            case "keys":
                parsed.keys = try parseKeys(body)
            case "ilst":
                for entry in try boxes(in: body) {
                    entriesByIndex[entry.typeBytes.bigEndianUInt32(at: 0)] = slice(body, entry.payloadOffset, entry.payloadSize)
                }
            default:
                parsed.others.append(slice(payload, child.offset, child.size))
            }
        }
        parsed.entries = (0 ..< parsed.keys.count).map { entriesByIndex[UInt32($0 + 1)] ?? Data() }
        return parsed
    }

    private static func parseKeys(_ body: Data) throws -> [(namespace: Data, name: Data)] {
        guard body.count >= 8 else { throw Failure.malformed }
        let count = Int(body.bigEndianUInt32(at: 4))
        var keys: [(namespace: Data, name: Data)] = []
        var position = 8
        for _ in 0 ..< count {
            guard position + 8 <= body.count else { throw Failure.malformed }
            let size = Int(body.bigEndianUInt32(at: position))
            guard size >= 8, position + size <= body.count else { throw Failure.malformed }
            keys.append((slice(body, UInt64(position + 4), 4), slice(body, UInt64(position + 8), UInt64(size - 8))))
            position += size
        }
        return keys
    }

    /// A `meta` box holding the existing keys (values preserved) with `values`
    /// replacing or extending them; written in QuickTime's form unless the
    /// existing box was ISO's.
    private static func metaBox(merging existing: Data?, with values: [(key: String, value: String)]) throws -> Data {
        var parsed = try existing.map(parseMeta) ?? ParsedMeta()
        for (key, value) in values {
            let name = Data(key.utf8)
            let entry = box("data", bigEndian(UInt32(1)) + bigEndian(UInt32(0)) + Data(value.utf8))
            if let index = parsed.keys.firstIndex(where: { $0.namespace == mdtaNamespace && $0.name == name }) {
                parsed.entries[index] = entry
            } else {
                parsed.keys.append((mdtaNamespace, name))
                parsed.entries.append(entry)
            }
        }
        var handler = Data(count: 8)
        handler.append(mdtaNamespace)
        handler.append(Data(count: 13))
        var keys = Data(count: 4)
        keys.append(bigEndian(UInt32(parsed.keys.count)))
        for key in parsed.keys {
            keys.append(bigEndian(UInt32(8 + key.name.count)))
            keys.append(key.namespace)
            keys.append(key.name)
        }
        var list = Data()
        for (index, entry) in parsed.entries.enumerated() {
            list.append(box(typeBytes: bigEndian(UInt32(index + 1)), entry))
        }
        var payload = parsed.isFullBox ? Data(count: 4) : Data()
        payload.append(box("hdlr", handler))
        payload.append(box("keys", keys))
        payload.append(box("ilst", list))
        for other in parsed.others {
            payload.append(other)
        }
        return box("meta", payload)
    }

    // MARK: - Bytes

    private static func read(_ handle: FileHandle, _ offset: UInt64, _ count: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(count)) ?? Data()
    }

    /// `count` bytes of `data` from `offset`, as a fresh `Data` (indices from 0);
    /// short when the range runs past the end.
    static func slice(_ data: Data, _ offset: UInt64, _ count: UInt64) -> Data {
        let start = data.startIndex + Int(min(offset, UInt64(data.count)))
        let end = data.startIndex + Int(min(offset + count, UInt64(data.count)))
        return Data(data[start ..< end])
    }

    static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

private extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0 ..< 4).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[start + $1]) }
    }

    func bigEndianUInt64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return (0 ..< 8).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[start + $1]) }
    }
}
