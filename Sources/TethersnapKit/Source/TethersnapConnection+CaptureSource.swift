import Foundation

/// A PTP device is a capture source: the library does the work, and the
/// cached DeviceInfo decides the thumbnail policy.
extension TethersnapConnection: CaptureSource {
    public var isValid: Bool {
        session.isValid
    }

    public func loadItems() throws -> [CaptureItem] {
        try library.loadItems()
    }

    public func thumbnailPayload(for item: CaptureItem) throws -> ThumbnailPayload? {
        try library.thumbnailPayload(
            for: item,
            deviceOffersThumbnails: supportsThumbnails,
            deviceOffersPartialObject: supportsPartialObject
        )
    }

    public func imageData(for item: CaptureItem) throws -> Data {
        try library.imageData(for: item)
    }

    @discardableResult
    public func download(_ item: CaptureItem, to directory: URL, skipExisting: Bool,
                         cancelToken: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws -> DownloadResult {
        try library.download(item, to: directory, skipExisting: skipExisting, cancelToken: cancelToken, progress: progress)
    }
}
