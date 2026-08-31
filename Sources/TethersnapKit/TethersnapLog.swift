import Foundation
import os
import Synchronization

/// Unified logging for the whole stack (subsystem `dev.luminoid.Tethersnap`).
///
/// Everything lands in the unified log; watch it with:
/// `log stream --level debug --predicate 'subsystem == "dev.luminoid.Tethersnap"'`
/// The CLI's `--verbose` additionally mirrors every message to stderr via
/// `echoToStderr`. The app enables `enableFileLogging()` so every run leaves a
/// complete debug trace at a stable path with zero setup.
public enum TethersnapLog {
    public static let subsystem = "dev.luminoid.Tethersnap"

    /// One log category: the `OSLog` handle for enablement checks plus the
    /// `Logger` that writes through it.
    public struct Channel: @unchecked Sendable {
        fileprivate let log: OSLog
        fileprivate let logger: Logger
        fileprivate let name: String

        fileprivate init(_ category: String) {
            log = OSLog(subsystem: TethersnapLog.subsystem, category: category)
            logger = Logger(log)
            name = category
        }
    }

    public static let usb = Channel("usb")
    public static let mtp = Channel("mtp")
    public static let library = Channel("library")
    public static let app = Channel("app")

    private static let stderrEcho = Mutex(false)

    public static var echoToStderr: Bool {
        get { stderrEcho.withLock { $0 } }
        set { stderrEcho.withLock { $0 = newValue } }
    }

    // MARK: - File sink

    private struct FileSink {
        let handle: FileHandle
        let formatter: ISO8601DateFormatter // only touched under the lock
    }

    private static let fileSink = Mutex<FileSink?>(nil)

    public static var isFileLoggingEnabled: Bool {
        fileSink.withLock { $0 != nil }
    }

    /// Where `enableFileLogging()` writes by default; the previous run is kept
    /// beside it as `Tethersnap.previous.log`.
    public static var defaultLogFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Tethersnap/Tethersnap.log")
    }

    /// Start mirroring every message (debug included) to `url`, rotating any
    /// existing file to `<name>.previous.log` first so the run before a crash
    /// stays inspectable. Returns the URL on success.
    @discardableResult
    public static func enableFileLogging(at url: URL = defaultLogFileURL) -> URL? {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }
        guard fileManager.createFile(atPath: url.path, contents: nil) else { return nil }
        // Handle and formatter are built inside the lock so no task-isolated
        // value crosses into the Mutex's sending closure (Swift 6 regions).
        let opened = fileSink.withLock { sink in
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            try? sink?.handle.close()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sink = FileSink(handle: handle, formatter: formatter)
            return true
        }
        return opened ? url : nil
    }

    /// Stop file logging and close the handle (tests, mainly).
    public static func disableFileLogging() {
        fileSink.withLock { sink in
            try? sink?.handle.close()
            sink = nil
        }
    }

    // MARK: - Emit

    /// Debug messages (hex previews, per-transaction traces) are hot-path; the
    /// autoclosure must only be evaluated when someone is actually listening.
    /// (With the file sink on, someone always is; one line per 512 KB chunk is
    /// noise-level next to the USB transfer itself.)
    public static func debug(_ channel: Channel, _ message: @autoclosure () -> String) {
        guard channel.log.isEnabled(type: .debug) || echoToStderr || isFileLoggingEnabled else { return }
        let text = message()
        channel.logger.debug("\(text, privacy: .public)")
        record("debug", channel: channel, text)
    }

    public static func info(_ channel: Channel, _ message: @autoclosure () -> String) {
        let text = message()
        channel.logger.info("\(text, privacy: .public)")
        record("info", channel: channel, text)
    }

    public static func error(_ channel: Channel, _ message: @autoclosure () -> String) {
        let text = message()
        channel.logger.error("\(text, privacy: .public)")
        record("error", channel: channel, text)
    }

    /// Hex dump of a buffer's first bytes, for wire-level traces.
    public static func hexPreview(_ data: Data, limit: Int = 16) -> String {
        let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > limit ? "\(shown) … (\(data.count) bytes)" : "\(shown) (\(data.count) bytes)"
    }

    private static func record(_ level: String, channel: Channel, _ text: String) {
        if echoToStderr {
            fputs("[tethersnap \(level)] \(text)\n", stderr)
        }
        fileSink.withLock { sink in
            guard let sink else { return }
            let line = "\(sink.formatter.string(from: Date())) [\(level)] \(channel.name): \(text)\n"
            try? sink.handle.write(contentsOf: Data(line.utf8))
        }
    }
}
