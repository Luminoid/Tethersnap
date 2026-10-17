import Foundation

/// Bytes for a grid thumbnail plus whether they are the whole object.
public struct ThumbnailPayload: Sendable {
    public let data: Data
    /// False when `data` is a bounded prefix that may fail to decode; the
    /// caller then falls back to `imageData(for:)`.
    public let isComplete: Bool

    public init(data: Data, isComplete: Bool) {
        self.data = data
        self.isComplete = isComplete
    }
}

/// Result of one `download` call.
public struct DownloadResult: Sendable {
    public let url: URL
    /// True when an existing same-size file was kept instead of re-downloading.
    public let skippedExisting: Bool

    public init(url: URL, skippedExisting: Bool) {
        self.url = url
        self.skippedExisting = skippedExisting
    }
}

/// Something that holds photos and videos Tethersnap can list, preview, and
/// export: a console or camera over PTP (`TethersnapConnection`) or a mounted
/// volume / opened folder (`VolumeCaptureSource`).
///
/// Not Sendable by design: a PTP source wraps the synchronous USB stack and a
/// volume source wraps a filesystem root, so a source is confined to one
/// actor (the app's service) or one thread (the CLI).
public protocol CaptureSource: AnyObject {
    var descriptor: CaptureSourceDescriptor { get }
    /// False once the backing session desynchronized or the volume vanished;
    /// discard the source and reopen it.
    var isValid: Bool { get }

    /// Every capture, in enumeration order (callers sort). Duplicate filenames
    /// get disambiguated `exportFilename`s.
    func loadItems() throws -> [CaptureItem]
    /// Bytes for a grid thumbnail, or nil when the item has no cheap preview.
    func thumbnailPayload(for item: CaptureItem) throws -> ThumbnailPayload?
    /// Full bytes in memory (image preview; avoid for videos).
    func imageData(for item: CaptureItem) throws -> Data
    /// Copy one capture into `directory` as `item.exportFilename`, preserving
    /// its capture date as the file modification date.
    @discardableResult
    func download(_ item: CaptureItem, to directory: URL, skipExisting: Bool,
                  cancelToken: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws -> DownloadResult
    /// Release the device or folder. Idempotent.
    func close()
    /// Release a source the system already reported gone (a USB device
    /// unplugged, a volume ejected): `close()` minus any round trip to the
    /// device, which could only fail or block until its timeout.
    func abandon()
}

public extension CaptureSource {
    func abandon() {
        close()
    }
}

public extension CaptureSource {
    @discardableResult
    func download(_ item: CaptureItem, to directory: URL) throws -> DownloadResult {
        try download(item, to: directory, skipExisting: false, cancelToken: nil, progress: nil)
    }
}
