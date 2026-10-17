import Foundation
import TethersnapKit

/// Owns the (non-Sendable) open capture source and serializes every operation
/// on it. Blocking USB and disk I/O runs inside the actor on its own dispatch
/// queue (not the cooperative pool, which multi-second synchronous transfers
/// would starve), which keeps callers responsive and makes concurrent UI
/// requests (thumbnails vs. export) queue up safely.
actor SourceService {
    private var source: (any CaptureSource)?
    private nonisolated let executorQueue = DispatchSerialQueue(label: "dev.luminoid.Tethersnap.SourceService")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    struct OpenedSource {
        /// The post-open descriptor: a PTP device reports its model and firmware.
        let descriptor: CaptureSourceDescriptor
        let items: [CaptureItem]
    }

    /// Outcome of one export run; `cancelled` means it stopped early.
    struct ExportOutcome {
        var saved = 0
        var skipped = 0
        var cancelled = false
    }

    private static let dragFolderPrefix = "tethersnap-drag-"
    /// A drag folder untouched this long is one Finder finished copying from.
    private static let dragFolderGrace: TimeInterval = 300

    /// Everything attached right now: USB devices (consoles first), then
    /// mounted external volumes. IOKit and mount-table lookups stay off main.
    func attachedSources() -> [CaptureSourceDescriptor] {
        CaptureSources.attached()
    }

    /// False once the open source desynchronized (PTP) or vanished (volume),
    /// or when nothing is open.
    func isValid() -> Bool {
        source?.isValid ?? false
    }

    /// Open `descriptor`, closing whatever was open, and enumerate its captures.
    func open(_ descriptor: CaptureSourceDescriptor) throws -> OpenedSource {
        close()
        let opened = try CaptureSources.open(descriptor)
        source = opened
        let items = try opened.loadItems()
        return OpenedSource(descriptor: opened.descriptor, items: items)
    }

    func reloadItems() throws -> [CaptureItem] {
        try openSource().loadItems()
    }

    /// Bytes for a grid thumbnail (device thumbnail, bounded image prefix, full
    /// image, or a locally generated one for files; nil when there is no cheap
    /// preview). Errors propagate so the model can log them and check the session.
    func thumbnailPayload(for item: CaptureItem) throws -> ThumbnailPayload? {
        try Task.checkCancellation()
        return try openSource().thumbnailPayload(for: item)
    }

    /// Full image bytes (preview).
    func fullImageData(for item: CaptureItem) throws -> Data {
        try Task.checkCancellation()
        return try openSource().imageData(for: item)
    }

    /// Download each destination's item into its directory (one folder, or a
    /// subfolder per source folder; the model decides from the view mode).
    /// `progress` reports (items completed, fraction of the current file); the
    /// fraction resets to 0 as each item starts, so a skipped file cannot leave
    /// a stale bar. Cancellation is an outcome, not an error, so partial save
    /// counts survive.
    func download(_ destinations: [ExportDestination],
                  cancelToken: CancelToken?,
                  progress: @escaping @Sendable (Int, Double) -> Void) throws -> ExportOutcome {
        let source = try openSource()
        // A SIGKILL mid-export leaves a `.name.tethersnap-partial` that nothing
        // else deletes; each existing destination folder is listed once, off main.
        for directory in Set(destinations.map(\.directory)) where FileSystem.isDirectory(directory) {
            TemporaryFiles.reapStale(in: directory)
        }
        var outcome = ExportOutcome()
        for (index, destination) in destinations.enumerated() {
            if let cancelToken, cancelToken.isCancelled {
                outcome.cancelled = true
                break
            }
            progress(index, 0)
            do {
                let result = try source.download(destination.item, to: destination.directory, skipExisting: true, cancelToken: cancelToken) { received, total in
                    progress(index, total > 0 ? Double(received) / Double(total) : 0)
                }
                if result.skippedExisting {
                    outcome.skipped += 1
                } else {
                    outcome.saved += 1
                }
            } catch is CancellationError {
                outcome.cancelled = true
                break
            }
            progress(index + 1, 0)
        }
        return outcome
    }

    /// Export the dragged captures into a fresh temporary folder. A single
    /// item hands back its file URL (a file-backed one needs no copy at all);
    /// several hand back a named folder (a SwiftUI drag carries one file
    /// promise), with a subfolder per source folder when `groupedByFolder`.
    func exportToTemporary(_ items: [CaptureItem], groupedByFolder: Bool) throws -> URL {
        if items.count == 1, let url = items[0].fileURL {
            return url
        }
        let source = try openSource()
        // Earlier drags of this run that Finder is done with go first.
        Self.reapDragTemporaries(olderThan: Self.dragFolderGrace)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.dragFolderPrefix)\(UUID().uuidString)")
        let directory = items.count > 1
            ? container.appendingPathComponent(L10n.dragFolderName)
            : container
        var lastFile: URL?
        for destination in items.exportDestinations(under: directory, groupedByFolder: items.count > 1 && groupedByFolder) {
            try Task.checkCancellation()
            lastFile = try source.download(destination.item, to: destination.directory).url
        }
        guard items.count == 1, let lastFile else { return directory }
        return lastFile
    }

    /// Remove leftover drag-export folders (each drag mints one and Finder
    /// copies out of it; nothing else ever deletes them). At launch everything
    /// goes; mid-run and at quit only folders not written to for `age`, since
    /// a drop that just landed may still be copying.
    nonisolated static func reapDragTemporaries(olderThan age: TimeInterval = 0) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in entries where url.lastPathComponent.hasPrefix(dragFolderPrefix) {
            if age > 0 {
                let modified = (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
                guard modified < cutoff else { continue }
            }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Which of `urls` are directories right now, by path. Runs off the main
    /// actor on purpose: a path on an unmounted autofs or SMB share blocks for
    /// the mount timeout, and the actor queue may be inside a long transfer.
    @concurrent
    nonisolated static func existingDirectories(among urls: [URL]) async -> Set<String> {
        Set(urls.filter { FileSystem.isDirectory($0) }.map(\.path))
    }

    /// `detached`: the source is already gone (a USB unplug, an ejected
    /// volume), so it is abandoned without a round trip to the device.
    func close(detached: Bool = false) {
        if detached {
            source?.abandon()
        } else {
            source?.close()
        }
        source = nil
    }

    private func openSource() throws -> any CaptureSource {
        guard let source else { throw CaptureSourceError.noOpenSource }
        return source
    }
}
