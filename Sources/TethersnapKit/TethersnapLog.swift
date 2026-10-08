//
//  TethersnapLog.swift
//  TethersnapKit
//
//  Logging core: levels, entries, and the write functions over os.Logger.
//  Categories live in TethersnapLog+Categories.swift.
//

import Foundation
import os

// MARK: - TethersnapLogLevel

/// Log severity, lowest to highest. The names follow `os.Logger`'s methods.
public nonisolated enum TethersnapLogLevel: String, Sendable, CaseIterable, Comparable, Codable {
    /// Development detail. Never saved on device.
    case debug
    /// Helpful context. Kept in memory only, so usually missing from a sysdiagnose.
    case info
    /// A normal but significant event (configuration, lifecycle). Saved on device.
    case notice
    /// Something went wrong, but the operation recovered or degraded.
    case warning
    /// An operation failed.
    case error
    /// A bug: an invariant the package relies on is broken.
    case fault

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The unified-logging type this level is written at (`warning` matches `Logger.warning`).
    public var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning, .error: .error
        case .fault: .fault
        }
    }

    private var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - TethersnapLogEntry

/// One written log line, as ``TethersnapLog/handler`` receives it.
public nonisolated struct TethersnapLogEntry: Sendable, Hashable {
    /// When the line was written.
    public let timestamp: Date
    /// Severity.
    public let level: TethersnapLogLevel
    /// Category name, e.g. "Session".
    public let category: String
    /// The public text: the message, plus an attached error's summary in brackets.
    public let message: String
    /// User data and full error descriptions; redacted in field logs.
    public let privateDetail: String?
    /// The call site's file name.
    public let file: String
    /// The call site's line.
    public let line: Int

    public init(timestamp: Date = Date(), level: TethersnapLogLevel, category: String, message: String, privateDetail: String? = nil, file: String = "", line: Int = 0) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.privateDetail = privateDetail
        self.file = file
        self.line = line
    }

    /// `[File.swift:12] message`, or the message alone when the call site is unknown.
    public var formattedMessage: String {
        file.isEmpty ? message : "[\(file):\(line)] \(message)"
    }
}

// MARK: - TethersnapLog

/// Logging on `os.Logger` under subsystem ``subsystem``.
///
/// - ``minimumLevel`` (default `.info`) sets how much is written. It is clamped at `.error`,
///   so errors and faults always reach the unified log and the handler.
/// - ``handler`` receives every written entry in addition to the unified log, for forwarding
///   to an app's own log store or crash reporter.
/// - Message text is public: keep it to static text, codes, ids, counts, and dimensions.
///   Pass user data (URLs, file paths, payloads) as `private:`.
///
/// Watch it live: `log stream --level debug --predicate 'subsystem == "dev.luminoid.Tethersnap"'`
public nonisolated enum TethersnapLog {
    /// The unified-logging subsystem every line is written under.
    public static let subsystem = "dev.luminoid.Tethersnap"

    /// A log category. The package declares its categories as static members.
    public struct Category: Sendable {
        /// The category name shown in Console.
        public let name: String
        fileprivate let logger: Logger

        package init(_ name: String) {
            self.name = name
            logger = Logger(subsystem: TethersnapLog.subsystem, category: name)
        }
    }

    private struct State {
        var minimumLevel: TethersnapLogLevel = .info
        var handler: (@Sendable (TethersnapLogEntry) -> Void)?
        var onceKeys: Set<String> = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// A threshold and handler bound to the current task by `withScopedConfiguration`.
    private struct Scope: Sendable {
        let minimumLevel: TethersnapLogLevel
        let handler: (@Sendable (TethersnapLogEntry) -> Void)?
    }

    @TaskLocal private static var scope: Scope?

    // MARK: - Configuration

    /// Lines below this level are not written. Default `.info`; values above `.error` clamp to `.error`.
    public static var minimumLevel: TethersnapLogLevel {
        get { state.withLock { $0.minimumLevel } }
        set { state.withLock { $0.minimumLevel = min(newValue, .error) } }
    }

    /// Receives every written entry, after the unified log, on the logging thread.
    public static var handler: (@Sendable (TethersnapLogEntry) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    /// Runs `body` with a threshold and handler that apply only to the current task and its child tasks,
    /// leaving the process-wide ``minimumLevel`` and ``handler`` untouched. For tests, which run in parallel
    /// and share the process-wide settings. The threshold clamps at `.error` like ``minimumLevel``.
    package static func withScopedConfiguration<R>(
        minimumLevel: TethersnapLogLevel,
        handler: (@Sendable (TethersnapLogEntry) -> Void)?,
        _ body: () throws -> R
    ) rethrows -> R {
        try $scope.withValue(Scope(minimumLevel: min(minimumLevel, .error), handler: handler), operation: body)
    }

    /// The threshold and handler in effect: the task's scoped configuration, else the process-wide one.
    private static func effectiveConfiguration() -> (minimumLevel: TethersnapLogLevel, handler: (@Sendable (TethersnapLogEntry) -> Void)?) {
        if let scope {
            return (scope.minimumLevel, scope.handler)
        }
        return state.withLock { ($0.minimumLevel, $0.handler) }
    }

    // MARK: - Writing

    /// Whether a line at `level` would be written; use it to skip work that only feeds a log line.
    package static func isLogging(_ level: TethersnapLogLevel) -> Bool {
        level >= effectiveConfiguration().minimumLevel
    }

    package static func debug(
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(.debug, category, message(), private: detail(), error: error, file: file, line: line)
    }

    package static func info(
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(.info, category, message(), private: detail(), error: error, file: file, line: line)
    }

    package static func notice(
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(.notice, category, message(), private: detail(), error: error, file: file, line: line)
    }

    package static func warning(
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(.warning, category, message(), private: detail(), error: error, file: file, line: line)
    }

    package static func error(
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(.error, category, message(), private: detail(), error: error, file: file, line: line)
    }

    package static func fault(
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(.fault, category, message(), private: detail(), error: error, file: file, line: line)
    }

    /// Writes one line. The message and detail closures run only when the line is written.
    package static func log(
        _ level: TethersnapLogLevel,
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        let configuration = effectiveConfiguration()
        guard level >= configuration.minimumLevel else { return }

        var publicText = message()
        var privateParts: [String] = []
        if let detail = detail() {
            privateParts.append(detail)
        }
        if let error {
            let described = describe(error)
            publicText += " [\(described.summary)]"
            if let errorDetail = described.detail {
                privateParts.append(errorDetail)
            }
        }
        let privateText = privateParts.isEmpty ? nil : privateParts.joined(separator: " | ")
        let fileName = file.split(separator: "/").last.map(String.init) ?? file
        let location = "[\(fileName):\(line)]"
        if let privateText {
            category.logger.log(level: level.osLogType, "\(location, privacy: .public) \(publicText, privacy: .public) | \(privateText, privacy: .private)")
        } else {
            category.logger.log(level: level.osLogType, "\(location, privacy: .public) \(publicText, privacy: .public)")
        }
        configuration.handler?(TethersnapLogEntry(level: level, category: category.name, message: publicText, privateDetail: privateText, file: fileName, line: line))
    }

    /// Writes a line once per `key` until ``resetOnce(_:)``, for failures on per-frame or polling paths.
    /// Keys should come from a small fixed set; each is remembered until reset.
    package static func once(
        _ key: String,
        _ level: TethersnapLogLevel,
        _ category: Category,
        _ message: @autoclosure () -> String,
        private detail: @autoclosure () -> String? = nil,
        error: (any Error)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        guard isLogging(level), state.withLock({ $0.onceKeys.insert(key).inserted }) else { return }
        log(level, category, message(), private: detail(), error: error, file: file, line: line)
    }

    /// Re-arms a ``once(_:_:_:_:private:error:file:line:)`` key, typically when the failing state clears.
    package static func resetOnce(_ key: String) {
        state.withLock { _ = $0.onceKeys.remove(key) }
    }

    // MARK: - Errors

    /// Splits an error into a public summary and a private detail.
    ///
    /// - Swift enum errors summarize as `Module.Type.case`, plus the summary of an error payload.
    /// - Other errors summarize as NSError domain and code, plus the underlying error's domain and code.
    /// - The detail is the full `String(describing:)`, which may carry user data; `nil` when the summary already says it all.
    public static func describe(_ error: any Error) -> (summary: String, detail: String?) {
        let full = String(describing: error)
        let summary: String
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            let payload = mirror.children.first
            var text = "\(String(reflecting: type(of: error))).\(payload?.label ?? full)"
            if let inner = payload.flatMap({ firstError(in: $0.value) }) {
                text += " <- \(describe(inner).summary)"
            }
            summary = text
        } else {
            let nsError = error as NSError
            var text = "\(nsError.domain) \(nsError.code)"
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                text += " <- \(underlying.domain) \(underlying.code)"
            }
            summary = text
        }
        return (summary, summary.hasSuffix(full) ? nil : full)
    }

    /// An enum payload's error: the payload itself, or the first error among its (possibly labeled) tuple elements.
    private static func firstError(in payload: Any) -> (any Error)? {
        if let error = payload as? any Error {
            return error
        }
        return Mirror(reflecting: payload).children.lazy.compactMap { $0.value as? any Error }.first
    }
}
