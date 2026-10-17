import Foundation

/// Enumerates a PTP responder's captures over an open `MTPSession`, downloads
/// them to disk, and fetches thumbnail/preview bytes.
public final class CaptureLibrary {
    private let session: MTPSession

    /// Enumeration logs a progress line this often; a camera card holds
    /// thousands of objects and each costs a GetObjectInfo round trip.
    private static let progressLogInterval = 250
    /// Enumeration stops here with a notice (the volume source has the same
    /// cap), so a card with tens of thousands of objects stays bounded.
    public static let itemLimit = 20000

    public init(session: MTPSession) {
        self.session = session
    }

    /// List every capture on the responder, in enumeration order (callers sort).
    /// Duplicate filenames across storages get disambiguated `exportFilename`s.
    ///
    /// The flat "all objects in the store" query is tried first; cameras accept
    /// it, and the folder names come from the association objects in the same
    /// list. The real Switch 2 rejects it (InvalidObjectHandle, observed
    /// 2026-08-30 fw 22.5.0), so the recursive walk from the root association
    /// (per-game folders) is the path that runs on the console; keep both. A
    /// single undecodable or rejected object is skipped, not fatal, and so are
    /// a rejected sub-folder and a storage that reports itself unavailable (an
    /// empty card slot). A transport failure is fatal: a truncated list must
    /// never pass for a complete one.
    public func loadItems() throws -> [CaptureItem] {
        let storageIDs = try session.storageIDs()
        if storageIDs.isEmpty {
            TethersnapLog.warning(.library, "responder reports zero storages; it may not be ready yet")
        }
        var items: [CaptureItem] = []
        var budget = Self.itemLimit
        for storageID in storageIDs {
            // Low 16 bits zero: a physical store with no logical store (PIMA 15740 §5.4).
            guard storageID & 0xFFFF != 0 else {
                TethersnapLog.debug(.library, "skipping storage 0x\(String(format: "%08X", storageID)): no logical store")
                continue
            }
            guard budget > 0 else { break }
            let flatHandles: [UInt32]?
            do {
                flatHandles = try session.objectHandles(storageID: storageID, parent: nil)
            } catch let MTPError.deviceResponse(code) {
                TethersnapLog.notice(.library, "flat object query rejected (\(code)) on storage 0x\(String(format: "%08X", storageID)); walking folders instead")
                flatHandles = nil
            }
            if let flatHandles {
                try items.append(contentsOf: flatItems(handles: flatHandles, storageID: storageID, budget: &budget))
            } else {
                do {
                    var visited: Set<UInt32> = []
                    try items.append(contentsOf: recursiveItems(
                        storageID: storageID, parent: PTPWildcard.rootParent, folderName: nil, visited: &visited, budget: &budget
                    ))
                } catch let MTPError.deviceResponse(code) {
                    TethersnapLog.warning(.library, "storage 0x\(String(format: "%08X", storageID)) unavailable (\(code)); skipping it")
                }
            }
        }
        if budget == 0 {
            TethersnapLog.notice(.library, "stopped enumerating at \(Self.itemLimit) captures")
        }
        TethersnapLog.notice(.library, "enumerated \(items.count) captures across \(storageIDs.count) storage(s)")
        return items.resolvingFilenameCollisions()
    }

    /// Flat path: every object of the store in one list, associations
    /// included, so a capture's folder is the association its `parentObject`
    /// names (DCIM → 100CANON → IMG_0001.JPG groups under "100CANON").
    private func flatItems(handles: [UInt32], storageID: UInt32, budget: inout Int) throws -> [CaptureItem] {
        var captures: [(handle: UInt32, info: PTPObjectInfo)] = []
        var associations: [UInt32: String] = [:]
        for (index, handle) in handles.enumerated() {
            guard budget > 0 else { break }
            if index > 0, index.isMultiple(of: Self.progressLogInterval) {
                TethersnapLog.info(.library, "enumerated \(index)/\(handles.count) objects on storage 0x\(String(format: "%08X", storageID))")
            }
            guard let info = try tolerantObjectInfo(for: handle) else { continue }
            if info.isAssociation {
                associations[handle] = info.filename
            } else {
                captures.append((handle, info))
                budget -= 1
            }
        }
        return captures.compactMap { capture in
            Self.captureItem(handle: capture.handle, info: capture.info, folderName: associations[capture.info.parentObject])
        }
    }

    /// One handle's ObjectInfo, or nil when it is skipped: a malformed dataset
    /// or a per-object rejection is logged and dropped (D3). A transport-level
    /// failure propagates: it invalidates the session, so every later handle
    /// would fail the same way and the enumeration must not pass for complete.
    private func tolerantObjectInfo(for handle: UInt32) throws -> PTPObjectInfo? {
        do {
            return try session.objectInfo(for: handle)
        } catch let MTPError.malformedData(detail) {
            TethersnapLog.warning(.library, "skipping object 0x\(String(format: "%08X", handle)): malformed ObjectInfo (\(detail))")
        } catch let MTPError.deviceResponse(code) {
            TethersnapLog.warning(.library, "skipping object 0x\(String(format: "%08X", handle)): response \(code)")
        }
        return nil
    }

    /// `folderName` is the name of the association being walked; captures
    /// inherit it (on the Switch 2 the folders are per-game, so it drives the
    /// app's by-folder grouping). `visited` guards against a responder that
    /// lists a folder among its own descendants (PTP mandates a tree, but the
    /// alternative is a stack overflow).
    private func recursiveItems(storageID: UInt32, parent: UInt32, folderName: String?,
                                visited: inout Set<UInt32>, budget: inout Int) throws -> [CaptureItem] {
        guard visited.insert(parent).inserted else {
            TethersnapLog.warning(.library, "folder 0x\(String(format: "%08X", parent)) listed twice; skipping the repeat")
            return []
        }
        let handles = try session.objectHandles(storageID: storageID, parent: parent)
        var items: [CaptureItem] = []
        for handle in handles {
            guard budget > 0 else { break }
            guard let info = try tolerantObjectInfo(for: handle) else { continue }
            if info.isAssociation {
                TethersnapLog.debug(.library, "walking folder 0x\(String(format: "%08X", handle))", private: info.filename)
                do {
                    try items.append(contentsOf: recursiveItems(
                        storageID: storageID, parent: handle, folderName: info.filename, visited: &visited, budget: &budget
                    ))
                } catch let MTPError.deviceResponse(code) {
                    // A folder deleted between the parent listing and this query
                    // (or one the responder refuses) costs its own contents, not
                    // the whole storage.
                    TethersnapLog.warning(.library, "skipping folder 0x\(String(format: "%08X", handle)): response \(code)", private: info.filename)
                }
            } else if let item = Self.captureItem(handle: handle, info: info, folderName: folderName) {
                items.append(item)
                budget -= 1
            }
        }
        return items
    }

    private static func captureItem(handle: UInt32, info: PTPObjectInfo, folderName: String?) -> CaptureItem? {
        guard !info.isAssociation else { return nil }
        let filename = usableFilename(info.filename, handle: handle, objectFormat: info.objectFormat)
        guard let kind = CaptureItem.kind(forFilename: filename, objectFormat: info.objectFormat) else { return nil }
        return CaptureItem(
            handle: handle,
            storageID: info.storageID,
            filename: filename,
            kind: kind,
            sizeInBytes: Int64(info.compressedSize),
            thumbSizeInBytes: Int64(info.thumbCompressedSize),
            date: info.bestDate,
            folderName: folderName
        )
    }

    /// A responder may report an empty or degenerate filename ("", "..", a
    /// name with a slash). A synthetic one from the handle keeps the item
    /// exportable without ever resolving to the export folder itself or to a
    /// path outside it.
    private static func usableFilename(_ reported: String, handle: UInt32, objectFormat: UInt16) -> String {
        guard !DownloadWriter.isUsableFilename(reported) else { return reported }
        let stem = String(format: "%08X", handle)
        let name = PTPObjectFormat.preferredExtension(objectFormat).map { "\(stem).\($0)" } ?? stem
        TethersnapLog.warning(.library, "object 0x\(stem) reports an unusable filename; exporting as \(name)", private: reported)
        return name
    }

    private static func handle(of item: CaptureItem) throws -> UInt32 {
        guard let handle = item.handle else { throw CaptureSourceError.foreignItem }
        return handle
    }

    // MARK: - Thumbnails & previews

    /// Device-generated thumbnail bytes, or nil when the item has none.
    private func thumbnailData(for item: CaptureItem) throws -> Data? {
        guard item.thumbSizeInBytes > 0 else { return nil }
        let handle = try Self.handle(of: item)
        var data = Data()
        try session.thumb(for: handle, sink: { data.append($0) })
        return data.isEmpty ? nil : data
    }

    /// Full object bytes in memory (images for preview; avoid for videos).
    public func imageData(for item: CaptureItem) throws -> Data {
        let handle = try Self.handle(of: item)
        var data = Data()
        try session.object(for: handle, sink: { data.append($0) })
        return data
    }

    /// First `maxBytes` of the object via GetPartialObject, for thumbnailing
    /// images when the responder offers no GetThumb.
    private func imageDataPrefix(for item: CaptureItem, maxBytes: UInt32) throws -> Data {
        try session.partialObject(for: Self.handle(of: item), maxBytes: maxBytes)
    }

    /// Grid-thumbnail capability policy: the device thumbnail when the
    /// responder offers one, else a bounded image prefix for images when
    /// GetPartialObject is supported, else the full image, else nil (a video
    /// without a device thumbnail has no cheap preview).
    /// A thrown GetThumb is NOT swallowed: the session may be desynchronized,
    /// and issuing GetObject right after would compound it.
    public func thumbnailPayload(for item: CaptureItem,
                                 deviceOffersThumbnails: Bool,
                                 deviceOffersPartialObject: Bool,
                                 prefixBytes: UInt32 = 256 * 1024) throws -> ThumbnailPayload? {
        _ = try Self.handle(of: item)
        if deviceOffersThumbnails, item.thumbSizeInBytes > 0,
           let thumb = try thumbnailData(for: item) {
            return ThumbnailPayload(data: thumb, isComplete: true)
        }
        guard item.kind == .image else { return nil }
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
        let handle = try Self.handle(of: item)
        return try DownloadWriter.write(item, to: directory, skipExisting: skipExisting, cancelToken: cancelToken, progress: progress) { sink in
            try session.object(for: handle, sink: sink)
        }
    }
}
