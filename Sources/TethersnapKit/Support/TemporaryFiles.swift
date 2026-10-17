import Foundation

/// Naming and cleanup of the Finder-invisible temp files Tethersnap writes
/// beside its outputs: download partials and date-rewrite scratch copies.
/// Every in-process failure removes its own temp file; this reaper is for
/// the ones a killed process left behind.
public enum TemporaryFiles {
    static let partialSuffix = ".tethersnap-partial"
    static let dateRewriteMarker = ".tethersnap-dates"

    /// `.<name>.tethersnap-partial` next to `destination`.
    static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)\(partialSuffix)")
    }

    /// `.<stem>.tethersnap-dates.<ext>` next to `original`; the extension is
    /// kept because AVAssetExportSession picks the container from it.
    static func dateRewriteURL(for original: URL) -> URL {
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? ".\(stem)\(dateRewriteMarker)" : ".\(stem)\(dateRewriteMarker).\(ext)"
        return original.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// True for a file this module wrote as scratch (enumerations skip them).
    static func isTemporary(_ filename: String) -> Bool {
        filename.hasSuffix(partialSuffix) || filename.contains(dateRewriteMarker)
    }

    /// Delete temp files in `directory` that have not been written to for
    /// `age` seconds (an active download keeps touching its partial). Returns
    /// the number removed; failures are logged, never thrown.
    @discardableResult
    public static func reapStale(in directory: URL,
                                 recursive: Bool = false,
                                 olderThan age: TimeInterval = 600,
                                 fileManager: FileManager = .default) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .nameKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: options) else {
            return 0
        }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let name = values.name, isTemporary(name),
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
                TethersnapLog.notice(.library, "removed a stale temp file left by an earlier run", private: url.path)
            } catch {
                TethersnapLog.warning(.library, "could not remove a stale temp file", private: url.path, error: error)
            }
        }
        return removed
    }
}
