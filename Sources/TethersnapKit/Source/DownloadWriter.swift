import Foundation

/// Shared disk side of every download: skip-by-size, a Finder-invisible
/// partial file, an atomic replace into place, and the capture date stamped as
/// the modification date. The source supplies the bytes through `producer`.
enum DownloadWriter {
    /// `producer` receives a sink and streams the object's bytes into it. The
    /// sink checks `cancelToken` before each chunk (throwing `CancellationError`)
    /// and reports progress; any error thrown through it removes the partial file.
    /// `category` is the log category of the calling source (`.library` for
    /// PTP, `.volume` for files).
    static func write(_ item: CaptureItem,
                      to directory: URL,
                      skipExisting: Bool,
                      cancelToken: CancelToken?,
                      progress: ((Int64, Int64) -> Void)?,
                      category: TethersnapLog.Category = .library,
                      producer: (_ sink: (Data) throws -> Void) throws -> Void) throws -> DownloadResult {
        let destination = directory.appendingPathComponent(item.exportFilename)
        // A degenerate name ("", ".", "..", or one with a slash) would resolve
        // the destination to the export folder itself or outside it, and the
        // replace below would then clobber a directory. Refuse before any I/O.
        guard isUsableFilename(item.exportFilename),
              destination.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            TethersnapLog.error(category, "refusing to export an unusable filename (\(item.origin))", private: item.exportFilename)
            throw CaptureSourceError.invalidFilename(item.filename)
        }
        let fileManager = FileManager.default
        if skipExisting, existingFileMatches(item, at: destination) {
            TethersnapLog.debug(category, "skipping an existing file of the same size", private: destination.path)
            return DownloadResult(url: destination, skippedExisting: true)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            TethersnapLog.error(category, "could not create the export folder", private: directory.path, error: error)
            throw error
        }

        TethersnapLog.debug(category, "downloading \(item.sizeInBytes) bytes", private: "\(item.origin) to \(destination.path)")
        let temporary = TemporaryFiles.partialURL(for: destination)
        let fileHandle: FileHandle
        do {
            // Creates or truncates the partial file, throwing the real reason on failure.
            try Data().write(to: temporary)
            fileHandle = try FileHandle(forWritingTo: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            TethersnapLog.error(category, "could not open the partial file for \(item.exportFilename)", private: temporary.path, error: error)
            throw error
        }

        // Everything through the final replace is guarded: any failure removes
        // the (Finder-invisible) dot-prefixed partial file instead of leaking it.
        var written: Int64 = 0
        do {
            try producer { chunk in
                if let cancelToken, cancelToken.isCancelled { throw CancellationError() }
                try fileHandle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress?(written, item.sizeInBytes)
            }
            try fileHandle.close()
            // One atomic step: the destination is the old file or the new one,
            // never missing in between.
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } catch {
            try? fileHandle.close()
            try? fileManager.removeItem(at: temporary)
            if error is CancellationError {
                TethersnapLog.notice(category, "download cancelled after \(written)/\(item.sizeInBytes) bytes", private: destination.path)
            } else {
                TethersnapLog.error(category, "download failed after \(written)/\(item.sizeInBytes) bytes", private: destination.path, error: error)
            }
            throw error
        }

        if let date = item.date {
            do {
                try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
            } catch {
                TethersnapLog.warning(category, "could not set the capture date", private: destination.path, error: error)
            }
        }
        TethersnapLog.info(category, "downloaded \(written) bytes", private: destination.path)
        return DownloadResult(url: destination, skippedExisting: false)
    }

    /// A name that can be a single path component inside the export folder.
    static func isUsableFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// A file only counts as "already exported" when its size matches. The PTP
    /// size is 32-bit and 0xFFFFFFFF means "unknown" (4 GiB or more); such
    /// items skip on existence. File-backed sizes are exact and always compare.
    static func existingFileMatches(_ item: CaptureItem, at destination: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let existingSize = attributes[.size] as? Int64 else { return false }
        let unknownPTPSize = item.handle != nil && item.sizeInBytes >= Int64(UInt32.max)
        let sizeKnown = item.sizeInBytes > 0 && !unknownPTPSize
        return !sizeKnown || existingSize == item.sizeInBytes
    }
}
