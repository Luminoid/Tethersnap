import Foundation
import Synchronization

// MARK: - Categories

/// Tethersnap's log categories. The lowercase names are what `log show`/`log stream`
/// predicates match (`category == "usb"`).
package extension TethersnapLog.Category {
    /// IOUSBHost discovery, interface claims, bulk transfers, stall recovery.
    static let usb = TethersnapLog.Category("usb")
    /// PTP sessions and transactions.
    static let mtp = TethersnapLog.Category("mtp")
    /// Capture enumeration and downloads.
    static let library = TethersnapLog.Category("library")
    /// The app's state machine and exports.
    static let app = TethersnapLog.Category("app")
}

// MARK: - Local sinks

/// Local mirrors of the log, layered on the core through ``TethersnapLog/handler``:
/// the CLI's `--verbose` stderr echo and the app's log file.
///
/// Turning either sink on installs one combined writer as ``TethersnapLog/handler`` and
/// lowers ``TethersnapLog/minimumLevel`` to `.debug`, so debug lines reach the sinks.
/// Turning both off clears the handler and restores the previous threshold. The app and
/// the CLI own ``TethersnapLog/handler``: nothing else should set it while a sink is on.
public extension TethersnapLog {
    /// Mirror every line (debug included) to stderr as `HH:mm:ss.SSS [level] category: message`.
    static var echoToStderr: Bool {
        get { LogSinks.shared.echoToStderr }
        set {
            LogSinks.shared.echoToStderr = newValue
            syncSinkInstallation()
        }
    }

    static var isFileLoggingEnabled: Bool {
        LogSinks.shared.isFileLoggingEnabled
    }

    /// Where ``enableFileLogging(at:)`` writes by default; the previous run is kept
    /// beside it as `Tethersnap.previous.log`.
    static var defaultLogFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Tethersnap/Tethersnap.log")
    }

    /// Start mirroring every line (debug included) to `url`, first rotating an existing
    /// file to `<name>.previous.log` so the run before a crash stays inspectable.
    ///
    /// A failed rotation is logged as a warning and logging continues. A file that cannot
    /// be created or opened is logged as an error and thrown, so the caller can tell the user.
    @discardableResult
    static func enableFileLogging(at url: URL = defaultLogFileURL) throws -> URL {
        let rotationError: (any Error)?
        do {
            rotationError = try LogSinks.shared.openFile(at: url)
        } catch {
            Self.error(.app, "file log unavailable", private: url.path, error: error)
            throw error
        }
        syncSinkInstallation()
        if let rotationError {
            warning(.app, "could not keep the previous run's log", private: url.path, error: rotationError)
        }
        return url
    }

    /// Stop file logging and close the file.
    static func disableFileLogging() {
        LogSinks.shared.closeFile()
        syncSinkInstallation()
    }

    /// Hex dump of a buffer's first bytes, for wire-level traces.
    static func hexPreview(_ data: Data, limit: Int = 16) -> String {
        let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > limit ? "\(shown) … (\(data.count) bytes)" : "\(shown) (\(data.count) bytes)"
    }

    /// The threshold in force before the first sink turned on; nil while no sink is on.
    private static let levelBeforeSinks = Mutex<TethersnapLogLevel?>(nil)

    /// Installs the sink writer when the first sink turns on and removes it when the last one turns off.
    private static func syncSinkInstallation() {
        levelBeforeSinks.withLock { savedLevel in
            let isActive = LogSinks.shared.isActive
            if isActive, savedLevel == nil {
                savedLevel = minimumLevel
                minimumLevel = .debug
                handler = { LogSinks.shared.write($0) }
            } else if !isActive, let previous = savedLevel {
                minimumLevel = previous
                handler = nil
                savedLevel = nil
            }
        }
    }
}

// MARK: - LogSinks

/// The sink state and line formats. One shared instance backs ``TethersnapLog``;
/// tests make their own so they never touch the global handler or threshold.
final class LogSinks: Sendable {
    static let shared = LogSinks()

    private struct State {
        var echoToStderr = false
        var file: FileHandle?
    }

    private let state = Mutex(State())

    var echoToStderr: Bool {
        get { state.withLock { $0.echoToStderr } }
        set { state.withLock { $0.echoToStderr = newValue } }
    }

    var isFileLoggingEnabled: Bool {
        state.withLock { $0.file != nil }
    }

    var isActive: Bool {
        state.withLock { $0.echoToStderr || $0.file != nil }
    }

    /// Rotates an existing file to `<name>.previous.log`, then opens a fresh file at `url`.
    /// Returns the rotation error, if any (the new file is still opened); throws when the
    /// directory or the file cannot be created or opened.
    func openFile(at url: URL) throws -> (any Error)? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var rotationError: (any Error)?
        if fileManager.fileExists(atPath: url.path) {
            let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
            do {
                if fileManager.fileExists(atPath: previous.path) {
                    try fileManager.removeItem(at: previous)
                }
                try fileManager.moveItem(at: url, to: previous)
            } catch {
                rotationError = error
            }
        }
        // Creates or truncates the file, throwing the real reason on failure.
        try Data().write(to: url)
        // Opened inside the lock so no task-isolated value crosses into the Mutex's
        // sending closure (Swift 6 regions).
        try state.withLock { state in
            let handle = try FileHandle(forWritingTo: url)
            try? state.file?.close()
            state.file = handle
        }
        return rotationError
    }

    func closeFile() {
        state.withLock { state in
            try? state.file?.close()
            state.file = nil
        }
    }

    /// Writes one entry to every active sink. Runs on the logging thread and must not log:
    /// a line written from here would come straight back through the handler.
    func write(_ entry: TethersnapLogEntry) {
        state.withLock { state in
            if state.echoToStderr {
                fputs(Self.stderrLine(for: entry), stderr)
            }
            // A failed write (disk full, file deleted) can't be logged from here; the
            // unified log still has the line.
            try? state.file?.write(contentsOf: Data(Self.fileLine(for: entry).utf8))
        }
    }

    // MARK: - Line formats

    /// `2026-10-02T14:13:20.250Z [notice] usb: message | private detail`, newline-terminated.
    /// The file is the user's own, so private detail is written in full.
    static func fileLine(for entry: TethersnapLogEntry) -> String {
        let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(entry.timestamp)
        return "\(timestamp) \(body(of: entry))\n"
    }

    /// `14:13:20.250 [notice] usb: message | private detail` in local time, newline-terminated.
    static func stderrLine(for entry: TethersnapLogEntry, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
            timeZone: timeZone,
            calendar: calendar
        )
        return "\(clock.format(entry.timestamp)) \(body(of: entry))\n"
    }

    private static func body(of entry: TethersnapLogEntry) -> String {
        let detail = entry.privateDetail.map { " | \($0)" } ?? ""
        return "[\(entry.level.rawValue)] \(entry.category): \(entry.message)\(detail)"
    }
}
