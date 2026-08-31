import Foundation

/// Enumerates the console's captures over an open `MTPSession`, downloads them
/// to disk, and fetches thumbnail/preview bytes.
public final class CaptureLibrary {
    private let session: MTPSession

    /// Result of one `download` call.
    public struct DownloadResult: Sendable {
        public let url: URL
        /// True when an existing same-size file was kept instead of re-downloading.
        public let skippedExisting: Bool
    }

    /// Bytes for a grid thumbnail plus whether they are the whole object.
    public struct ThumbnailPayload: Sendable {
        public let data: Data
        /// False when `data` is a bounded prefix that may fail to decode; the
        /// caller then falls back to `imageData(for:)`.
        public let isComplete: Bool
    }

    public init(session: MTPSession) {
        self.session = session
    }

    /// List every capture on the console, in enumeration order (callers sort).
    /// Duplicate filenames across storages get disambiguated `exportFilename`s.
    ///
    /// The flat "all objects in the store" query is tried first, but the real
    /// console rejects it (InvalidObjectHandle, observed 2026-08-30 fw 22.5.0),
    /// so the recursive walk from the root association (Album → date folders)
    /// is the path that actually runs on hardware; keep both. A single
    /// undecodable or rejected object is skipped, not fatal.
    public func loadItems() throws -> [CaptureItem] {
        let storageIDs = try session.storageIDs()
        if storageIDs.isEmpty {
            TethersnapLog.info(TethersnapLog.library, "responder reports zero storages; it may not be ready yet")
        }
        var items: [CaptureItem] = []
        for storageID in storageIDs {
            do {
                let handles = try session.objectHandles(storageID: storageID, parent: nil)
                for handle in handles {
                    appendItem(for: handle, to: &items)
                }
            } catch MTPError.deviceResponse {
                try items.append(contentsOf: recursiveItems(storageID: storageID, parent: PTPWildcard.rootParent, folderName: nil))
            }
        }
        TethersnapLog.info(TethersnapLog.library, "enumerated \(items.count) captures across \(storageIDs.count) storage(s)")
        return Self.resolvingFilenameCollisions(items)
    }

    /// Fetch one handle's info and append it when it is a capture; a malformed
    /// dataset or a per-object rejection is logged and skipped (D3), while
    /// transport-level failures propagate.
    private func appendItem(for handle: UInt32, to items: inout [CaptureItem]) {
        do {
            let info = try session.objectInfo(for: handle)
            if let item = Self.captureItem(handle: handle, info: info) {
                items.append(item)
            }
        } catch let MTPError.malformedData(detail) {
            TethersnapLog.error(TethersnapLog.library, "skipping object 0x\(String(format: "%08X", handle)): malformed ObjectInfo (\(detail))")
        } catch let MTPError.deviceResponse(code) {
            TethersnapLog.error(TethersnapLog.library, "skipping object 0x\(String(format: "%08X", handle)): response \(code)")
        } catch {
            // Session-level failures surface on the next transaction as
            // sessionInvalidated; log this one and let the caller find out.
            TethersnapLog.error(TethersnapLog.library, "object 0x\(String(format: "%08X", handle)) failed: \(error.localizedDescription)")
        }
    }

    /// `folderName` is the name of the association being walked; captures
    /// inherit it (on the Switch 2 the folders are per-game, so it drives the
    /// app's by-game grouping).
    private func recursiveItems(storageID: UInt32, parent: UInt32, folderName: String?) throws -> [CaptureItem] {
        let handles = try session.objectHandles(storageID: storageID, parent: parent)
        var items: [CaptureItem] = []
        for handle in handles {
            let info: PTPObjectInfo
            do {
                info = try session.objectInfo(for: handle)
            } catch let MTPError.malformedData(detail) {
                TethersnapLog.error(TethersnapLog.library, "skipping object 0x\(String(format: "%08X", handle)): malformed ObjectInfo (\(detail))")
                continue
            } catch let MTPError.deviceResponse(code) {
                TethersnapLog.error(TethersnapLog.library, "skipping object 0x\(String(format: "%08X", handle)): response \(code)")
                continue
            }
            if info.isAssociation {
                TethersnapLog.debug(TethersnapLog.library, "walking folder \(info.filename) (0x\(String(format: "%08X", handle)))")
                try items.append(contentsOf: recursiveItems(storageID: storageID, parent: handle, folderName: info.filename))
            } else if let item = Self.captureItem(handle: handle, info: info, folderName: folderName) {
                items.append(item)
            }
        }
        return items
    }

    private static func captureItem(handle: UInt32, info: PTPObjectInfo, folderName: String? = nil) -> CaptureItem? {
        guard !info.isAssociation, let kind = CaptureItem.kind(forFilename: info.filename) else { return nil }
        return CaptureItem(
            handle: handle,
            storageID: info.storageID,
            filename: info.filename,
            kind: kind,
            sizeInBytes: Int64(info.compressedSize),
            thumbSizeInBytes: Int64(info.thumbCompressedSize),
            date: info.bestDate,
            folderName: folderName
        )
    }

    /// Two storages can hold the same filename; exporting both to one folder
    /// must not silently overwrite or skip, so later duplicates get a numbered
    /// `exportFilename` ("name-2.jpg").
    private static func resolvingFilenameCollisions(_ items: [CaptureItem]) -> [CaptureItem] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let key = item.filename.lowercased()
            let occurrence = seen[key, default: 0] + 1
            seen[key] = occurrence
            guard occurrence > 1 else { return item }
            var copy = item
            copy.exportFilename = disambiguated(item.filename, occurrence: occurrence)
            TethersnapLog.info(TethersnapLog.library, "duplicate filename \(item.filename) (storage 0x\(String(format: "%08X", item.storageID))); exporting as \(copy.exportFilename)")
            return copy
        }
    }

    private static func disambiguated(_ filename: String, occurrence: Int) -> String {
        let name = filename as NSString
        let stem = name.deletingPathExtension
        let ext = name.pathExtension
        return ext.isEmpty ? "\(stem)-\(occurrence)" : "\(stem)-\(occurrence).\(ext)"
    }

    // MARK: - Thumbnails & previews

    /// Device-generated thumbnail bytes, or nil when the item has none.
    public func thumbnailData(for item: CaptureItem) throws -> Data? {
        guard item.thumbSizeInBytes > 0 else { return nil }
        var data = Data()
        try session.thumb(for: item.handle, sink: { data.append($0) })
        return data.isEmpty ? nil : data
    }

    /// Full object bytes in memory (screenshots for preview; avoid for videos).
    public func imageData(for item: CaptureItem) throws -> Data {
        var data = Data()
        try session.object(for: item.handle, sink: { data.append($0) })
        return data
    }

    /// First `maxBytes` of the object via GetPartialObject, for thumbnailing
    /// screenshots when the responder offers no GetThumb.
    public func imageDataPrefix(for item: CaptureItem, maxBytes: UInt32) throws -> Data {
        try session.partialObject(for: item.handle, maxBytes: maxBytes)
    }

    /// Grid-thumbnail capability policy: the device thumbnail when the
    /// responder offers one, else a bounded image prefix for screenshots when
    /// GetPartialObject is supported, else the full image for screenshots,
    /// else nil (a video without a device thumbnail has no cheap preview).
    /// A thrown GetThumb is NOT swallowed: the session may be desynchronized,
    /// and issuing GetObject right after would compound it.
    public func thumbnailPayload(for item: CaptureItem,
                                 deviceOffersThumbnails: Bool,
                                 deviceOffersPartialObject: Bool,
                                 prefixBytes: UInt32 = 256 * 1024) throws -> ThumbnailPayload? {
        if deviceOffersThumbnails, item.thumbSizeInBytes > 0,
           let thumb = try thumbnailData(for: item) {
            return ThumbnailPayload(data: thumb, isComplete: true)
        }
        guard item.kind == .screenshot else { return nil }
        if deviceOffersPartialObject {
            let prefix = try imageDataPrefix(for: item, maxBytes: prefixBytes)
            if !prefix.isEmpty {
                return ThumbnailPayload(data: prefix, isComplete: Int64(prefix.count) >= item.sizeInBytes)
            }
        }
        return try ThumbnailPayload(data: imageData(for: item), isComplete: true)
    }

    // MARK: - Download

    /// Download one capture to `directory`, preserving its capture date as the
    /// file modification date.
    ///
    /// A `cancelToken` fired mid-file abandons the PTP data phase, which leaves
    /// the session desynchronized: throw the connection away and reconnect.
    @discardableResult
    public func download(_ item: CaptureItem,
                         to directory: URL,
                         skipExisting: Bool = false,
                         cancelToken: CancelToken? = nil,
                         progress: ((Int64, Int64) -> Void)? = nil) throws -> DownloadResult {
        let destination = directory.appendingPathComponent(item.exportFilename)
        let fileManager = FileManager.default
        if skipExisting, Self.existingFileMatches(item, at: destination) {
            TethersnapLog.debug(TethersnapLog.library, "skipping existing \(item.exportFilename)")
            return DownloadResult(url: destination, skippedExisting: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        TethersnapLog.info(TethersnapLog.library, "downloading \(item.exportFilename) (\(item.sizeInBytes) bytes, storage 0x\(String(format: "%08X", item.storageID)))")
        let temporary = directory.appendingPathComponent(".\(item.exportFilename).tethersnap-partial")
        fileManager.createFile(atPath: temporary.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: temporary)

        // Everything through the final move is guarded: any failure removes the
        // (Finder-invisible) dot-prefixed partial file instead of leaking it.
        do {
            try session.object(for: item.handle, sink: { chunk in
                if let cancelToken, cancelToken.isCancelled { throw CancellationError() }
                try fileHandle.write(contentsOf: chunk)
            }, progress: { received in
                progress?(received, item.sizeInBytes)
            })
            try fileHandle.close()
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileHandle.close()
            try? fileManager.removeItem(at: temporary)
            if error is CancellationError {
                TethersnapLog.info(TethersnapLog.library, "download of \(item.exportFilename) cancelled")
            } else {
                TethersnapLog.error(TethersnapLog.library, "download of \(item.exportFilename) failed: \(error.localizedDescription)")
            }
            throw error
        }

        if let date = item.date {
            do {
                try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
            } catch {
                TethersnapLog.error(TethersnapLog.library, "could not set capture date on \(item.exportFilename): \(error.localizedDescription)")
            }
        }
        return DownloadResult(url: destination, skippedExisting: false)
    }

    /// A file only counts as "already exported" when its size matches (the PTP
    /// size is 32-bit and 0xFFFFFFFF means "unknown"; those skip on existence).
    private static func existingFileMatches(_ item: CaptureItem, at destination: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let existingSize = attributes[.size] as? Int64 else { return false }
        let sizeKnown = item.sizeInBytes > 0 && item.sizeInBytes < Int64(UInt32.max)
        return !sizeKnown || existingSize == item.sizeInBytes
    }
}
