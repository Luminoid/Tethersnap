import Foundation

/// Stamps the date embedded in a capture's filename into the file: EXIF/XMP for
/// images, the QuickTime creation date for videos, and the Finder dates for all.
///
/// One bad file never aborts a run; it lands in the report as ``Outcome/failed(_:)``.
public struct CaptureDateFixer: Sendable {
    public struct Options: Sendable {
        /// Rewrite files that already carry an embedded date.
        public var overwrite = false
        /// Descend into subfolders of the folder being fixed.
        public var recursive = true
        /// Report what would change without touching any file.
        public var dryRun = false

        public init(overwrite: Bool = false, recursive: Bool = true, dryRun: Bool = false) {
            self.overwrite = overwrite
            self.recursive = recursive
            self.dryRun = dryRun
        }
    }

    public enum Outcome: Sendable {
        /// The date was written. `embedded == false` means only the Finder dates were set
        /// (camera RAW, WebP, GIF, BMP, WebM, AVI, MTS, or an image whose rewrite
        /// left no readable date).
        case updated(Date, embedded: Bool)
        /// An embedded date is present and ``Options/overwrite`` is off.
        case alreadyDated(Date)
        /// The filename carries no recognizable timestamp.
        case noDateInName
        /// The extension is outside the media set.
        case unsupported
        case failed(any Error)
    }

    public struct Entry: Sendable {
        public let url: URL
        public let outcome: Outcome
    }

    public struct Report: Sendable {
        public var entries: [Entry] = []
        /// The run stopped early because its token or task was cancelled.
        public var cancelled = false

        public init(entries: [Entry] = [], cancelled: Bool = false) {
            self.entries = entries
            self.cancelled = cancelled
        }

        public var updated: [URL] {
            entries.compactMap { if case .updated = $0.outcome { $0.url } else { nil } }
        }

        public var alreadyDated: [URL] {
            entries.compactMap { if case .alreadyDated = $0.outcome { $0.url } else { nil } }
        }

        public var noDateInName: [URL] {
            entries.compactMap { if case .noDateInName = $0.outcome { $0.url } else { nil } }
        }

        public var unsupported: [URL] {
            entries.compactMap { if case .unsupported = $0.outcome { $0.url } else { nil } }
        }

        public var failed: [(URL, any Error)] {
            entries.compactMap { if case let .failed(error) = $0.outcome { ($0.url, error) } else { nil } }
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Candidates

    /// Candidate files under `folder`, sorted by path. Hidden files and Tethersnap's own
    /// temp files (`*.tethersnap-partial`, `*.tethersnap-dates*`) are skipped; subfolders
    /// are descended only when `recursive`.
    public static func candidates(in folder: URL, recursive: Bool) throws -> [URL] {
        guard FileSystem.isDirectory(folder) else {
            throw DateFixError.notAFolder(folder.path)
        }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: options) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: keys).isRegularFile) == true,
                  !TemporaryFiles.isTemporary(url.lastPathComponent) else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Fixing

    /// Fixes every candidate under `folder`. A folder that cannot be listed yields a single
    /// ``Outcome/failed(_:)`` entry for the folder itself.
    @concurrent
    public func fix(
        folder: URL,
        cancelToken: CancelToken? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        onOutcome: (@Sendable (Entry) -> Void)? = nil
    ) async -> Report {
        let files: [URL]
        do {
            files = try Self.candidates(in: folder, recursive: options.recursive)
            // A killed run leaves its scratch copy beside the original; nothing
            // else ever deletes it.
            TemporaryFiles.reapStale(in: folder, recursive: options.recursive)
        } catch {
            TethersnapLog.error(.dates, "cannot list folder", private: folder.path, error: error)
            let entry = Entry(url: folder, outcome: .failed(error))
            onOutcome?(entry)
            return Report(entries: [entry])
        }
        return await fix(files: files, cancelToken: cancelToken, progress: progress, onOutcome: onOutcome)
    }

    /// Fixes `files` in order, calling `progress(done, total)` before and after each file and
    /// `onOutcome` per file. Stops (with ``Report/cancelled`` set) when `cancelToken` fires or
    /// the task is cancelled.
    @concurrent
    public func fix(
        files: [URL],
        cancelToken: CancelToken? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        onOutcome: (@Sendable (Entry) -> Void)? = nil
    ) async -> Report {
        var report = Report()
        let total = files.count
        TethersnapLog.notice(.dates, "fixing dates for \(total) file(s)\(options.dryRun ? " (dry run)" : "")")
        for (index, url) in files.enumerated() {
            if cancelToken?.isCancelled == true || Task.isCancelled {
                report.cancelled = true
                TethersnapLog.notice(.dates, "fix dates cancelled after \(index) of \(total) file(s)")
                break
            }
            progress?(index, total)
            let entry = await Entry(url: url, outcome: fix(file: url, cancelToken: cancelToken))
            report.entries.append(entry)
            onOutcome?(entry)
            progress?(index + 1, total)
        }
        let summary = "fixed dates: \(report.updated.count) updated, \(report.alreadyDated.count) already dated, "
            + "\(report.noDateInName.count) no date, \(report.unsupported.count) unsupported, \(report.failed.count) failed"
        TethersnapLog.notice(.dates, summary)
        return report
    }

    /// Fixes one file. Never throws: every failure is an ``Outcome/failed(_:)``.
    @concurrent
    public func fix(file: URL) async -> Outcome {
        await fix(file: file, cancelToken: nil)
    }

    // MARK: - Per-file flow

    private enum Kind {
        case image
        case video
        /// Media with no losslessly rewritable date tag (camera RAW, WebP, GIF,
        /// BMP, WebM, AVI, MTS): only the Finder dates are set.
        case fileDatesOnly
    }

    /// What the writers can rewrite without re-encoding; `CaptureItem` decides
    /// what counts as media at all, so a format added there lands here as
    /// `fileDatesOnly` until a writer learns it.
    private static let rewritableImageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"]
    private static let rewritableVideoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    private static func kind(of url: URL) -> Kind? {
        guard let media = CaptureItem.kind(forFilename: url.lastPathComponent) else { return nil }
        let ext = url.pathExtension.lowercased()
        switch media {
        case .image where rewritableImageExtensions.contains(ext): return .image
        case .video where rewritableVideoExtensions.contains(ext): return .video
        case .image, .video: return .fileDatesOnly
        }
    }

    private func fix(file url: URL, cancelToken: CancelToken?) async -> Outcome {
        guard let kind = Self.kind(of: url) else {
            TethersnapLog.debug(.dates, "unsupported extension", private: url.path)
            return .unsupported
        }
        guard let date = FilenameDate.parse(url.lastPathComponent) else {
            TethersnapLog.debug(.dates, "no date in filename", private: url.path)
            return .noDateInName
        }
        do {
            if !options.overwrite, let existing = try await embeddedDate(at: url, kind: kind) {
                TethersnapLog.debug(.dates, "already dated", private: url.path)
                return .alreadyDated(existing)
            }
            if options.dryRun {
                TethersnapLog.debug(.dates, "would update (dry run)", private: url.path)
                return .updated(date, embedded: kind != .fileDatesOnly)
            }
            let embedded = try await embed(date, at: url, kind: kind, cancelToken: cancelToken)
            try FileDates.set(date, at: url)
            TethersnapLog.debug(.dates, embedded ? "updated" : "updated file dates only", private: url.path)
            return .updated(date, embedded: embedded)
        } catch {
            TethersnapLog.error(.dates, "date fix failed", private: url.path, error: error)
            return .failed(error)
        }
    }

    private func embeddedDate(at url: URL, kind: Kind) async throws -> Date? {
        switch kind {
        case .image: try ImageDateWriter.embeddedDate(at: url)
        case .video: try await VideoDateWriter.embeddedDate(at: url)
        case .fileDatesOnly: nil
        }
    }

    /// Writes the embedded date; returns false when the file keeps only its Finder dates.
    private func embed(_ date: Date, at url: URL, kind: Kind, cancelToken: CancelToken?) async throws -> Bool {
        switch kind {
        case .image:
            try ImageDateWriter.write(date, to: url)
            // ImageIO can report success for a container it only partly
            // supports; the read-back decides whether a date is really there.
            guard try ImageDateWriter.embeddedDate(at: url) != nil else {
                TethersnapLog.warning(.dates, "metadata rewrite left no readable date; file dates only", private: url.path)
                return false
            }
            return true
        case .video:
            try await VideoDateWriter.write(date, to: url, cancelToken: cancelToken)
            return true
        case .fileDatesOnly:
            return false
        }
    }
}
