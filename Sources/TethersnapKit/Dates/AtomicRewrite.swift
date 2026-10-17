import Foundation

/// Rewrites a file in place through a sibling temp file: `body` fills the
/// temp, then `replaceItemAt` swaps it in as one step (the original's
/// permissions and extended attributes carry over). Any failure, in `body` or
/// in the swap, removes the temp so nothing is left beside the original.
enum AtomicRewrite {
    /// Synchronous body (ImageIO).
    static func replace(_ url: URL, with body: (_ temp: URL) throws -> Void) throws {
        let temp = TemporaryFiles.dateRewriteURL(for: url)
        try? FileManager.default.removeItem(at: temp)
        do {
            try body(temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Asynchronous body (AVFoundation export).
    static func replace(_ url: URL, withAsync body: (_ temp: URL) async throws -> Void) async throws {
        let temp = TemporaryFiles.dateRewriteURL(for: url)
        try? FileManager.default.removeItem(at: temp)
        do {
            try await body(temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
