import Foundation

/// Captures on a mounted volume or an opened folder: enumerated by layout,
/// thumbnailed locally, and exported with the same partial-file discipline
/// as a PTP download.
public final class VolumeCaptureSource: CaptureSource {
    public let descriptor: CaptureSourceDescriptor
    public let root: URL
    public let layout: VolumeLayout
    /// Enumeration stops here with a notice, so a generic walk of a large
    /// drive stays bounded.
    public let itemLimit: Int

    private let fileManager = FileManager.default
    private static let copyChunkSize = 1 << 20
    private static let progressLogInterval = 250

    /// `descriptor` defaults to a folder descriptor for `root`; `layout` to
    /// detection. Throws `sourceUnavailable` when `root` is not a directory.
    public init(root: URL, descriptor: CaptureSourceDescriptor? = nil, layout: VolumeLayout? = nil, itemLimit: Int = 20000) throws {
        guard FileSystem.isDirectory(root, fileManager: fileManager) else {
            TethersnapLog.error(.volume, "source root is not a directory", private: root.path)
            throw CaptureSourceError.sourceUnavailable(root)
        }
        self.root = root
        self.descriptor = descriptor ?? .folder(root)
        self.layout = layout ?? VolumeLayout.detect(root: root)
        self.itemLimit = itemLimit
        TethersnapLog.notice(.volume, "opened \(self.descriptor.kind.rawValue) \(self.descriptor.name) (layout \(self.layout.rawValue))", private: root.path)
    }

    public var isValid: Bool {
        (try? root.checkResourceIsReachable()) == true
    }

    public func loadItems() throws -> [CaptureItem] {
        guard isValid else { throw CaptureSourceError.sourceUnavailable(root) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var items: [CaptureItem] = []
        var seenFiles = 0
        var truncated = false
        scan: for mediaRoot in layout.mediaRoots(under: root, fileManager: fileManager) {
            // Resolved once per media root: the per-file symlink walk is the
            // expensive part of a 20,000-entry card.
            let mediaRootComponents = VolumeLayout.resolvedComponents(of: mediaRoot)
            guard let enumerator = fileManager.enumerator(
                at: mediaRoot, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    TethersnapLog.warning(.volume, "skipping an unreadable entry", private: url.path, error: error)
                    return true
                }
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isDirectory == true {
                    if VolumeLayout.skippedDirectoryNames.contains(url.lastPathComponent)
                        || layout.maxDepth.map({ enumerator.level > $0 }) == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                seenFiles += 1
                if seenFiles.isMultiple(of: Self.progressLogInterval) {
                    TethersnapLog.info(.volume, "scanned \(seenFiles) files, \(items.count) captures so far", private: descriptor.logDetail)
                }
                let filename = url.lastPathComponent
                guard let kind = CaptureItem.kind(forFilename: filename) else { continue }
                items.append(CaptureItem(
                    origin: .file(url),
                    filename: filename,
                    kind: kind,
                    sizeInBytes: Int64(values?.fileSize ?? 0),
                    date: FilenameDate.parse(filename) ?? values?.creationDate ?? values?.contentModificationDate,
                    folderName: layout.folderName(for: url, mediaRootComponents: mediaRootComponents)
                ))
                if items.count >= itemLimit {
                    truncated = true
                    break scan
                }
            }
        }
        if truncated {
            TethersnapLog.notice(.volume, "stopped enumerating at \(itemLimit) items", private: descriptor.logDetail)
        }
        TethersnapLog.notice(.volume, "enumerated \(items.count) captures on the \(descriptor.logName) (layout \(layout.rawValue))", private: descriptor.logDetail)
        return items.resolvingFilenameCollisions()
    }

    /// Images are downsampled through ImageIO (RAW included); videos get a
    /// frame through AVFoundation, nil for containers it cannot read (WebM).
    public func thumbnailPayload(for item: CaptureItem) throws -> ThumbnailPayload? {
        let url = try Self.fileURL(of: item)
        let data: Data? = switch item.kind {
        case .image: VolumeThumbnailer.jpegThumbnail(forImageAt: url)
        case .video: VolumeThumbnailer.jpegThumbnail(forVideoAt: url)
        }
        return data.map { ThumbnailPayload(data: $0, isComplete: true) }
    }

    /// A plain read, never a mapping: the caller decodes these bytes after this
    /// call returns, and a mapped file on a card that is pulled meanwhile
    /// faults with SIGBUS instead of an error.
    public func imageData(for item: CaptureItem) throws -> Data {
        let url = try Self.fileURL(of: item)
        do {
            return try Data(contentsOf: url)
        } catch {
            TethersnapLog.error(.volume, "could not read \(item.filename)", private: url.path, error: error)
            throw CaptureSourceError.unreadableFile(url, underlying: error)
        }
    }

    @discardableResult
    public func download(_ item: CaptureItem, to directory: URL, skipExisting: Bool,
                         cancelToken: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws -> DownloadResult {
        let url = try Self.fileURL(of: item)
        return try DownloadWriter.write(
            item, to: directory, skipExisting: skipExisting, cancelToken: cancelToken, progress: progress, category: .volume
        ) { sink in
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw CaptureSourceError.unreadableFile(url, underlying: error)
            }
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: Self.copyChunkSize), !chunk.isEmpty {
                try sink(chunk)
            }
        }
    }

    public func close() {
        TethersnapLog.info(.volume, "closed the \(descriptor.logName)", private: descriptor.logDetail)
    }

    private static func fileURL(of item: CaptureItem) throws -> URL {
        guard let url = item.fileURL else { throw CaptureSourceError.foreignItem }
        return url
    }
}
