import Foundation

/// One photo or video on a capture source: a console or camera over PTP, or a
/// file on a mounted volume or opened folder.
public struct CaptureItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable {
        case image
        case video
    }

    /// Where the bytes live. A PTP handle is valid for the current session
    /// only; a file URL stays valid while its volume is mounted.
    public enum Origin: Sendable, Hashable, CustomStringConvertible {
        case ptp(handle: UInt32, storageID: UInt32)
        case file(URL)

        /// Short form for log lines; never the full path (paths go in `private:`).
        public var description: String {
            switch self {
            case let .ptp(handle, storageID):
                String(format: "0x%08X/0x%08X", storageID, handle)
            case let .file(url):
                "file:\(url.lastPathComponent)"
            }
        }
    }

    public let origin: Origin
    public let filename: String
    /// Destination filename for exports; differs from `filename` only when the
    /// source disambiguated a collision (two storages or folders holding the
    /// same name).
    public var exportFilename: String
    public let kind: Kind
    public let sizeInBytes: Int64
    /// Size of the device-generated thumbnail; 0 when the responder offers none
    /// (always 0 for file-backed items, which are thumbnailed locally).
    public let thumbSizeInBytes: Int64
    public let date: Date?
    /// Name of the immediate parent folder: per-game on a Switch or a PS5
    /// drive, `100CANON` on a camera card, the date folder on a Switch SD card.
    /// nil when enumeration had no folder context.
    public let folderName: String?

    public var id: Origin { origin }

    /// PTP object handle; nil for file-backed items.
    public var handle: UInt32? {
        if case let .ptp(handle, _) = origin { handle } else { nil }
    }

    /// PTP storage ID; nil for file-backed items.
    public var storageID: UInt32? {
        if case let .ptp(_, storageID) = origin { storageID } else { nil }
    }

    /// Backing file; nil for PTP items.
    public var fileURL: URL? {
        if case let .file(url) = origin { url } else { nil }
    }

    /// Camera RAW (CR3, NEF, ARW, DNG, …): previewable through ImageIO, but
    /// its bytes are never rewritten.
    /// `folderName` as a directory name an export can create: `/` and `:`
    /// (which the Finder would show as `/`) become `-`, whitespace collapses,
    /// leading dots go (they would hide the folder); nil when nothing usable
    /// is left, in which case the item stays at the export root.
    public var exportFolderName: String? {
        folderName.flatMap(Self.exportFolderComponent)
    }

    static func exportFolderComponent(_ name: String) -> String? {
        var cleaned = name
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: ": ", with: " - ")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        cleaned = String(cleaned.drop { $0 == "." })
        return cleaned.isEmpty ? nil : cleaned
    }

    public var isRawImage: Bool {
        kind == .image && Self.rawExtensions.contains(Self.fileExtension(of: filename))
    }

    public init(origin: Origin, filename: String, kind: Kind,
                sizeInBytes: Int64, thumbSizeInBytes: Int64 = 0, date: Date?, folderName: String? = nil) {
        self.origin = origin
        self.filename = filename
        exportFilename = filename
        self.kind = kind
        self.sizeInBytes = sizeInBytes
        self.thumbSizeInBytes = thumbSizeInBytes
        self.date = date
        self.folderName = folderName
    }

    /// PTP convenience: the handle/storage pair becomes the origin.
    public init(handle: UInt32, storageID: UInt32, filename: String, kind: Kind,
                sizeInBytes: Int64, thumbSizeInBytes: Int64 = 0, date: Date?, folderName: String? = nil) {
        self.init(
            origin: .ptp(handle: handle, storageID: storageID),
            filename: filename, kind: kind, sizeInBytes: sizeInBytes,
            thumbSizeInBytes: thumbSizeInBytes, date: date, folderName: folderName
        )
    }

    // MARK: - Classification

    /// Classify a file by extension; nil for anything that is not a photo or video.
    public static func kind(forFilename filename: String) -> Kind? {
        let ext = fileExtension(of: filename)
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Extension first (the one classifier PTP and file items share), then the
    /// PTP object format for files with an unknown or missing extension.
    public static func kind(forFilename filename: String, objectFormat: UInt16) -> Kind? {
        kind(forFilename: filename) ?? PTPObjectFormat.captureKind(objectFormat)
    }

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef",
    ]

    static let imageExtensions: Set<String> = Set([
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff",
    ]).union(rawExtensions)

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "avi", "mts", "m2ts",
    ]

    static func fileExtension(of filename: String) -> String {
        (filename as NSString).pathExtension.lowercased()
    }
}

public extension [CaptureItem] {
    /// Items of `kind`; nil means everything. Shared by the CLI filter flags
    /// and the app's filter picker.
    func matching(_ kind: CaptureItem.Kind?) -> [CaptureItem] {
        guard let kind else { return self }
        return filter { $0.kind == kind }
    }

    /// Newest first; undated items sort last. Shared by the CLI listing and
    /// the app's default sort order so the two never disagree on ties.
    func sortedNewestFirst() -> [CaptureItem] {
        sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Two storages (or two camera folders, `100CANON`/`101CANON`) can hold the
    /// same filename; exporting both to one folder must not silently overwrite
    /// or skip, so later duplicates get a numbered `exportFilename` ("name-2.jpg").
    /// Generated names count as taken too, so a later original `name-2.jpg`
    /// cannot collide with one.
    func resolvingFilenameCollisions() -> [CaptureItem] {
        var occurrences: [String: Int] = [:]
        var taken = Set(map { $0.filename.lowercased() })
        return map { item in
            let key = item.filename.lowercased()
            let occurrence = occurrences[key, default: 0] + 1
            occurrences[key] = occurrence
            guard occurrence > 1 else { return item }
            var candidate = occurrence
            var exportName = Self.disambiguated(item.filename, occurrence: candidate)
            while !taken.insert(exportName.lowercased()).inserted {
                candidate += 1
                exportName = Self.disambiguated(item.filename, occurrence: candidate)
            }
            var copy = item
            copy.exportFilename = exportName
            TethersnapLog.notice(.library, "duplicate filename; a flat export writes it under a numbered name", private: "\(item.filename) (\(item.origin)) as \(copy.exportFilename)")
            return copy
        }
    }

    private static func disambiguated(_ filename: String, occurrence: Int) -> String {
        let name = filename as NSString
        let stem = name.deletingPathExtension
        let ext = name.pathExtension
        return ext.isEmpty ? "\(stem)-\(occurrence)" : "\(stem)-\(occurrence).\(ext)"
    }
}
