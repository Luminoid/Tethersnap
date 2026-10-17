import Foundation

/// Errors from the source layer that are not PTP failures.
public enum CaptureSourceError: Error {
    /// The item's origin does not belong to this source (a file item handed to
    /// a PTP source, or the reverse).
    case foreignItem
    /// The volume was unmounted or the folder removed.
    case sourceUnavailable(URL)
    /// A file could not be read from the volume.
    case unreadableFile(URL, underlying: Error)
    /// An operation needs an open source and none is.
    case noOpenSource
    /// The source reported a filename that cannot name a file on disk (empty,
    /// `.`, `..`, or containing a slash); the item is refused rather than
    /// exported to a path outside the export folder.
    case invalidFilename(String)
}

extension CaptureSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .foreignItem:
            KitStrings.localized("error.foreign_item")
        case .noOpenSource:
            KitStrings.localized("error.no_open_source")
        case let .invalidFilename(name):
            String(format: KitStrings.localized("error.invalid_filename"), name)
        case let .sourceUnavailable(url):
            String(format: KitStrings.localized("error.source_unavailable"), url.path)
        case let .unreadableFile(url, underlying):
            String(format: KitStrings.localized("error.unreadable_file"), url.lastPathComponent, underlying.localizedDescription)
        }
    }
}
