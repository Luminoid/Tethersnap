import AVFoundation
import Foundation

/// Reads and writes the creation date of MP4/MOV files by re-muxing them through a
/// passthrough `AVAssetExportSession`: the samples are copied, never re-encoded.
enum VideoDateWriter {
    /// Metadata identifiers that carry the creation date; all are replaced on write.
    private static let creationDateIdentifiers: [AVMetadataIdentifier] = [
        .commonIdentifierCreationDate, .quickTimeMetadataCreationDate, .quickTimeUserDataCreationDate, .isoUserDataDate,
    ]

    /// The embedded creation date, or nil when the container carries none.
    ///
    /// Explicit metadata items come first: `AVAsset.creationDate` falls back to the movie
    /// header's creation time, which every muxer stamps with the mux time (a re-mux
    /// included), so it must not shadow the date tag this writer stores. A header time of
    /// zero (what many cameras write) yields nil.
    /// The asset is built here: `AVAsset` is not `Sendable`.
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

    /// Re-muxes the file at `url` with `date` as its creation date, through a sibling temp
    /// file. A fired `cancelToken` cancels the export.
    @concurrent
    static func write(_ date: Date, to url: URL, cancelToken: CancelToken?) async throws {
        if cancelToken?.isCancelled == true {
            throw CancellationError()
        }
        let ext = url.pathExtension.lowercased()
        let fileType: AVFileType = switch ext {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }
        try await AtomicRewrite.replace(url) { temp in
            // The session is built inside the child task: neither it nor the asset is Sendable.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await export(date, from: url, to: temp, as: fileType, container: ext)
                }
                if let cancelToken {
                    group.addTask {
                        while !cancelToken.isCancelled {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        throw CancellationError()
                    }
                }
                // The first child to finish decides: an export error or a cancellation
                // propagates and the group cancels the other child on the way out.
                try await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: - Helpers

    private static func export(_ date: Date, from url: URL, to temp: URL, as fileType: AVFileType, container ext: String) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw DateFixError.videoSessionUnavailable
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType) else {
            throw DateFixError.videoContainerUnsupported(ext)
        }

        // `session.metadata` replaces the source metadata wholesale, so carry it over
        // minus every creation-date item, which the two new items supersede.
        let stamp = MetadataDate.isoString(date, offsetColon: false)
        var metadata = try await asset.load(.metadata).filter { item in
            guard let identifier = item.identifier else { return true }
            return !creationDateIdentifiers.contains(identifier)
        }
        for identifier in [AVMetadataIdentifier.quickTimeMetadataCreationDate, .commonIdentifierCreationDate] {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = stamp as NSString
            item.extendedLanguageTag = "und"
            metadata.append(item)
        }
        session.metadata = metadata
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: temp, as: fileType)
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
