import Foundation
import Testing
@testable import TethersnapKit

/// The stderr echo and file sink. Every test uses its own `LogSinks`, never the shared
/// one, so nothing here touches the global handler or threshold the core tests check.
@Suite("TethersnapLog sinks")
struct TethersnapLogSinksTests {
    /// 2026-09-21 14:13:20.250 UTC; the fraction is exact in binary.
    private static let instant = Date(timeIntervalSince1970: 1_790_000_000.25)

    private static func entry(_ level: TethersnapLogLevel = .notice, detail: String? = nil) -> TethersnapLogEntry {
        TethersnapLogEntry(timestamp: instant, level: level, category: "usb", message: "claimed interface #0", privateDetail: detail)
    }

    @Test
    func `stderr lines carry a local clock time, the level, and the category`() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(LogSinks.stderrLine(for: Self.entry(), timeZone: utc) == "14:13:20.250 [notice] usb: claimed interface #0\n")

        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(LogSinks.stderrLine(for: Self.entry(.debug), timeZone: tokyo) == "23:13:20.250 [debug] usb: claimed interface #0\n")
    }

    @Test
    func `file lines carry an ISO-8601 timestamp and keep private detail`() {
        #expect(LogSinks.fileLine(for: Self.entry()) == "2026-09-21T14:13:20.250Z [notice] usb: claimed interface #0\n")
        #expect(LogSinks.fileLine(for: Self.entry(.warning, detail: "/Users/someone/Pictures"))
            == "2026-09-21T14:13:20.250Z [warning] usb: claimed interface #0 | /Users/someone/Pictures\n")
    }

    @Test
    func `the file sink writes every level and rotates the previous run`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-log-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("Tethersnap.log")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sinks = LogSinks()

        #expect(try sinks.openFile(at: url) == nil)
        #expect(sinks.isFileLoggingEnabled && sinks.isActive)
        sinks.write(TethersnapLogEntry(level: .info, category: "app", message: "first-run marker"))
        sinks.write(TethersnapLogEntry(level: .debug, category: "usb", message: "debug marker reaches the file sink"))
        sinks.closeFile()
        #expect(!sinks.isActive)
        let firstRun = try String(contentsOf: url, encoding: .utf8)
        #expect(firstRun.contains("[info] app: first-run marker"))
        #expect(firstRun.contains("[debug] usb: debug marker reaches the file sink"))

        #expect(try sinks.openFile(at: url) == nil)
        sinks.closeFile()
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
        let rotated = try String(contentsOf: previous, encoding: .utf8)
        #expect(rotated.contains("first-run marker"))
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)
    }

    @Test
    func `a log file that cannot be created throws instead of failing silently`() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let sinks = LogSinks()

        #expect(throws: (any Error).self) { try sinks.openFile(at: blocker.appendingPathComponent("Tethersnap.log")) }
        #expect(!sinks.isFileLoggingEnabled)
    }
}

@Suite("Version")
struct TethersnapVersionTests {
    @Test
    func `the CLI version matches the app bundle's CFBundleShortVersionString`() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TethersnapKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleShortVersionString"] as? String == TethersnapVersion.current)
    }
}
