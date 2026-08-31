import Foundation
import TethersnapKit

/// Owns the (non-Sendable) USB connection and serializes every MTP operation.
/// Blocking USB I/O runs inside the actor on its own dispatch queue (not the
/// cooperative pool, which multi-second synchronous transfers would starve),
/// which keeps callers responsive and makes concurrent UI requests
/// (thumbnails vs. export) queue up safely.
actor DeviceService {
    private var connection: TethersnapConnection?
    private nonisolated let executorQueue = DispatchSerialQueue(label: "dev.luminoid.Tethersnap.DeviceService")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    struct ConnectedDevice {
        let name: String
        let firmwareVersion: String
        let items: [CaptureItem]
    }

    /// Outcome of one export run; `cancelled` means it stopped early.
    struct ExportOutcome {
        var saved = 0
        var skipped = 0
        var cancelled = false
    }

    private static let dragFolderPrefix = "tethersnap-drag-"

    /// Name of an attached supported console, nil when none is present.
    func attachedDeviceName() -> String? {
        USBMTPTransport.attachedDeviceID()?.name
    }

    /// False once a failure desynchronized the PTP session (the connection
    /// must be rebuilt) or when there is no connection.
    func isSessionValid() -> Bool {
        connection?.isSessionValid ?? false
    }

    /// Claim the console and enumerate its captures.
    func connect() throws -> ConnectedDevice {
        disconnect()
        let connection = try TethersnapConnection.connect()
        self.connection = connection
        let items = try connection.library.loadItems()
        let info = connection.cachedDeviceInfo
        return ConnectedDevice(
            name: info.model.isEmpty ? connection.deviceID.name : info.model,
            firmwareVersion: info.deviceVersion,
            items: items
        )
    }

    func reloadItems() throws -> [CaptureItem] {
        guard let connection else { throw MTPError.deviceNotFound }
        return try connection.library.loadItems()
    }

    /// Bytes for a grid thumbnail (device thumbnail, bounded image prefix, or
    /// full screenshot; nil for a video without a device thumbnail). Errors
    /// propagate so the model can log them and check the session.
    func thumbnailPayload(for item: CaptureItem) throws -> CaptureLibrary.ThumbnailPayload? {
        try Task.checkCancellation()
        guard let connection else { throw MTPError.deviceNotFound }
        return try connection.library.thumbnailPayload(
            for: item,
            deviceOffersThumbnails: connection.supportsThumbnails,
            deviceOffersPartialObject: connection.supportsPartialObject
        )
    }

    /// Full object bytes (screenshot preview).
    func fullImageData(for item: CaptureItem) throws -> Data {
        try Task.checkCancellation()
        guard let connection else { throw MTPError.deviceNotFound }
        return try connection.library.imageData(for: item)
    }

    /// Download `items` into `directory`. `progress` reports (items completed,
    /// fraction of the current file); the fraction resets to 0 as each item
    /// starts, so a skipped file cannot leave a stale bar. Cancellation is an
    /// outcome, not an error, so partial save counts survive.
    func download(_ items: [CaptureItem],
                  to directory: URL,
                  cancelToken: CancelToken?,
                  progress: @escaping @Sendable (Int, Double) -> Void) throws -> ExportOutcome {
        guard let connection else { throw MTPError.deviceNotFound }
        var outcome = ExportOutcome()
        for (index, item) in items.enumerated() {
            if let cancelToken, cancelToken.isCancelled {
                outcome.cancelled = true
                break
            }
            progress(index, 0)
            do {
                let result = try connection.library.download(
                    item, to: directory, skipExisting: true, cancelToken: cancelToken
                ) { received, total in
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
    /// item hands back its file URL; several hand back a named folder (a
    /// SwiftUI drag carries one file promise).
    func exportToTemporary(_ items: [CaptureItem]) throws -> URL {
        guard let connection else { throw MTPError.deviceNotFound }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.dragFolderPrefix)\(UUID().uuidString)")
        let directory = items.count > 1
            ? container.appendingPathComponent(L10n.dragFolderName)
            : container
        var lastFile: URL?
        for item in items {
            try Task.checkCancellation()
            lastFile = try connection.library.download(item, to: directory).url
        }
        guard items.count == 1, let lastFile else { return directory }
        return lastFile
    }

    /// Remove leftover drag-export folders from earlier runs (each drag mints
    /// one and Finder copies out of it; nothing else ever deletes them).
    nonisolated static func reapDragTemporaries() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(dragFolderPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    func disconnect() {
        connection?.close()
        connection = nil
    }
}
