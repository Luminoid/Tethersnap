//
//  TethersnapLogTests.swift
//  TethersnapKitTests
//
//  Tests for the logging core in TethersnapLog.swift.
//

import Foundation
import os
import Testing
@testable import TethersnapKit

@Suite("TethersnapLog core", .serialized)
struct TethersnapLogTests {
    enum SampleError: Error {
        case timeout
        case failed(String)
        case wrapped(any Error)
        case labeled(underlying: any Error)
        case pair(String, underlying: any Error)
    }

    private final class Capture: Sendable {
        private let entries = OSAllocatedUnfairLock<[TethersnapLogEntry]>(initialState: [])

        func append(_ entry: TethersnapLogEntry) {
            entries.withLock { $0.append(entry) }
        }

        var all: [TethersnapLogEntry] {
            entries.withLock { $0 }.filter { $0.category == TethersnapLogTests.category.name }
        }
    }

    static let category = TethersnapLog.Category("LogCoreTests")

    /// Runs `body` with a capturing handler at `level`, scoped to this task. The process-wide
    /// configuration is never changed here: other suites log in parallel and rely on it.
    private func capturing(at level: TethersnapLogLevel = .info, _ body: () -> Void) -> [TethersnapLogEntry] {
        let capture = Capture()
        TethersnapLog.withScopedConfiguration(minimumLevel: level, handler: { capture.append($0) }, body)
        return capture.all
    }

    @Test
    func `levels are ordered and map to unified-logging types like os.Logger's methods`() {
        #expect(TethersnapLogLevel.allCases.sorted() == TethersnapLogLevel.allCases)
        #expect(TethersnapLogLevel.debug.osLogType == .debug)
        #expect(TethersnapLogLevel.info.osLogType == .info)
        #expect(TethersnapLogLevel.notice.osLogType == .default)
        #expect(TethersnapLogLevel.warning.osLogType == .error)
        #expect(TethersnapLogLevel.error.osLogType == .error)
        #expect(TethersnapLogLevel.fault.osLogType == .fault)
    }

    @Test
    func `the default threshold is info, and filtered lines are never built`() {
        #expect(TethersnapLog.minimumLevel == .info)
        var evaluated = false
        let entries = capturing {
            TethersnapLog.debug(Self.category, {
                evaluated = true
                return "hidden"
            }())
            TethersnapLog.info(Self.category, "shown")
        }
        #expect(!evaluated)
        #expect(entries.map(\.message) == ["shown"])
        #expect(entries.first?.file == "TethersnapLogTests.swift")
    }

    @Test
    func `the threshold clamps at error, so errors and faults always come through`() {
        let entries = capturing(at: .fault) {
            #expect(!TethersnapLog.isLogging(.warning))
            #expect(TethersnapLog.isLogging(.error))
            TethersnapLog.warning(Self.category, "dropped")
            TethersnapLog.error(Self.category, "kept")
            TethersnapLog.fault(Self.category, "kept too")
        }
        #expect(entries.map(\.level) == [.error, .fault])
    }

    @Test
    func `a scoped configuration leaves the process-wide settings alone`() {
        let entries = TethersnapLog.withScopedConfiguration(minimumLevel: .debug, handler: nil) {
            #expect(TethersnapLog.isLogging(.debug))
            #expect(TethersnapLog.minimumLevel == .info)
            return capturing(at: .warning) {
                TethersnapLog.notice(Self.category, "inner scope wins")
            }
        }
        #expect(entries.isEmpty)
        #expect(!TethersnapLog.isLogging(.debug))
    }

    @Test
    func `debug lines are written once the threshold is lowered`() {
        let entries = capturing(at: .debug) {
            TethersnapLog.debug(Self.category, "trace")
        }
        #expect(entries.map(\.level) == [.debug])
    }

    @Test
    func `private detail stays out of the public message`() {
        let entries = capturing {
            TethersnapLog.notice(Self.category, "Fetched page", private: "https://example.com/?token=secret")
        }
        #expect(entries.first?.message == "Fetched page")
        #expect(entries.first?.privateDetail == "https://example.com/?token=secret")
    }

    @Test
    func `an attached error adds its summary to the message and its description to the private detail`() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 60)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSUnderlyingErrorKey: underlying])
        let entries = capturing {
            TethersnapLog.error(Self.category, "Request failed", error: error)
        }
        #expect(entries.first?.message == "Request failed [NSURLErrorDomain -1001 <- NSPOSIXErrorDomain 60]")
        #expect(entries.first?.privateDetail?.contains("NSURLErrorDomain") == true)
    }

    @Test
    func `Swift enum errors summarize as type and case, keeping payloads private`() {
        let failed = TethersnapLog.describe(SampleError.failed("user text"))
        #expect(failed.summary.hasSuffix("SampleError.failed"))
        #expect(!failed.summary.contains("user text"))
        #expect(failed.detail?.contains("user text") == true)

        let timeout = TethersnapLog.describe(SampleError.timeout)
        #expect(timeout.summary.hasSuffix("SampleError.timeout"))
        #expect(timeout.detail == nil)

        let wrapped = TethersnapLog.describe(SampleError.wrapped(URLError(.timedOut)))
        #expect(wrapped.summary.hasSuffix("SampleError.wrapped <- NSURLErrorDomain -1001"))

        let labeled = TethersnapLog.describe(SampleError.labeled(underlying: URLError(.timedOut)))
        #expect(labeled.summary.hasSuffix("SampleError.labeled <- NSURLErrorDomain -1001"))

        let pair = TethersnapLog.describe(SampleError.pair("stage", underlying: URLError(.timedOut)))
        #expect(pair.summary.hasSuffix("SampleError.pair <- NSURLErrorDomain -1001"))
        #expect(!pair.summary.contains("stage"))
    }

    @Test
    func `once writes a key a single time until it is reset`() {
        let entries = capturing {
            for _ in 0 ..< 3 {
                TethersnapLog.once("test.flood", .error, Self.category, "Pool exhausted")
            }
            TethersnapLog.resetOnce("test.flood")
            TethersnapLog.once("test.flood", .error, Self.category, "Pool exhausted")
        }
        TethersnapLog.resetOnce("test.flood")
        #expect(entries.count == 2)
    }

    @Test
    func `formattedMessage prefixes the call site`() {
        let entry = TethersnapLogEntry(level: .info, category: "Test", message: "hello", file: "File.swift", line: 12)
        #expect(entry.formattedMessage == "[File.swift:12] hello")
        #expect(TethersnapLogEntry(level: .info, category: "Test", message: "hello").formattedMessage == "hello")
    }
}
