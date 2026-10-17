import AVFoundation
import Foundation

/// Reads the creation date and camera of MP4/MOV files through AVFoundation and
/// writes them with `MovieMetadataPatcher`: the `moov` box is rewritten in place
/// and every other byte of the file stays where it is.
enum VideoDateWriter {
    /// Metadata identifiers that carry the creation date; the patcher's key supersedes them.
    private static let creationDateIdentifiers: [AVMetadataIdentifier] = [
        .commonIdentifierCreationDate, .quickTimeMetadataCreationDate, .quickTimeUserDataCreationDate, .isoUserDataDate,
    ]
    private static let makeIdentifiers: [AVMetadataIdentifier] = [.quickTimeMetadataMake, .quickTimeUserDataMake]
    private static let locationIdentifiers: [AVMetadataIdentifier] = [.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709]

    /// The embedded creation date, or nil when the container carries none.
    ///
    /// Explicit metadata items come first: `AVAsset.creationDate` falls back to the movie
    /// header's creation time, which every muxer stamps with the mux time, so it must not
    /// shadow the date tag this writer stores. A header time of zero (what many cameras
    /// write) yields nil. The asset is built here: `AVAsset` is not `Sendable`.
    @concurrent
    static func embeddedDate(at url: URL) async throws -> Date? {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        for identifier in creationDateIdentifiers {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                if let date = try await date(of: item) {
                    return date
                }
            }
        }
        if let item = try await asset.load(.creationDate), let date = try await date(of: item) {
            return date
        }
        return nil
    }

    /// The camera make stored as metadata, nil when none. A clip whose make is
    /// present has had its record embedded.
    @concurrent
    static func embeddedMake(at url: URL) async throws -> String? {
        try await firstString(at: url, among: makeIdentifiers)
    }

    /// The ISO 6709 position stored as metadata, nil when none.
    @concurrent
    static func embeddedLocation(at url: URL) async throws -> String? {
        try await firstString(at: url, among: locationIdentifiers)
    }

    private static func firstString(at url: URL, among identifiers: [AVMetadataIdentifier]) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                if let value = try await item.load(.stringValue), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    /// Writes `date` (and the camera make, model, and position when `clip` carries them)
    /// into the file at `url`, through a sibling temp file. The `creationdate` key is
    /// rendered in the clip's zone, else the current one; the movie-header times get the
    /// same instant.
    @concurrent
    static func write(_ date: Date, clip: SonyClipMetadata? = nil, to url: URL, cancelToken: CancelToken?) async throws {
        if cancelToken?.isCancelled == true {
            throw CancellationError()
        }
        let metadata = MovieMetadataPatcher.Metadata(
            creationDate: date, timeZone: clip?.timeZone ?? .current, make: clip?.manufacturer, model: clip?.model, location: clip?.location
        )
        try MovieMetadataPatcher.patch(url, with: metadata)
    }

    private static func date(of item: AVMetadataItem) async throws -> Date? {
        if let date = try await item.load(.dateValue) {
            return date
        }
        if let string = try await item.load(.stringValue) {
            return MetadataDate.parse(string)
        }
        return nil
    }
}
