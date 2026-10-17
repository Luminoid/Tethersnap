import Foundation
import ImageIO
import Synchronization
import Testing
@testable import TethersnapKit

@Suite("Capture date fixer")
struct CaptureDateFixerTests {
    /// The outcome shape, without the payloads, for table comparisons.
    private enum Shape: Equatable {
        case updated(embedded: Bool)
        case alreadyDated
        case noDateInName
        case unsupported
        case failed
    }

    private static let switchName = "2026083012345600-02CB906EA538A35643C1E1484C4B947D.jpg"
    private static let datedName = "2026083012345700-02CB906EA538A35643C1E1484C4B947D.jpg"
    private static let nestedName = "2026083012345800-02CB906EA538A35643C1E1484C4B947D.jpg"
    private static let webmName = "Game_20260830123456.webm"
    private static let candidateCount = 6

    @Test
    func `A mixed folder yields one outcome per candidate and leaves dated files alone`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let datedBefore = try Data(contentsOf: folder.appendingPathComponent(Self.datedName))

        let report = await CaptureDateFixer().fix(folder: folder)

        #expect(report.entries.count == Self.candidateCount)
        #expect(!report.cancelled)
        #expect(Self.shape(report, Self.switchName) == .updated(embedded: true))
        #expect(Self.shape(report, Self.datedName) == .alreadyDated)
        #expect(Self.shape(report, "IMG_notadate.jpg") == .noDateInName)
        #expect(Self.shape(report, "readme.txt") == .unsupported)
        #expect(Self.shape(report, Self.webmName) == .updated(embedded: false))
        #expect(Self.shape(report, "nested/\(Self.nestedName)") == .updated(embedded: true))
        #expect(report.updated.count == 3)
        #expect(report.alreadyDated.count == 1)
        #expect(report.noDateInName.count == 1)
        #expect(report.unsupported.count == 1)
        #expect(report.failed.isEmpty)
        #expect(try Data(contentsOf: folder.appendingPathComponent(Self.datedName)) == datedBefore)
        #expect(ImageDateWriterTests.exifDateTimeOriginal(at: folder.appendingPathComponent(Self.switchName)) == "2026:08:30 12:34:56")
        // The hidden and partial files were never candidates.
        let names = Set(report.entries.map(\.url.lastPathComponent))
        #expect(!names.contains(".DS_Store"))
        #expect(!names.contains(".x.tethersnap-partial"))
    }

    @Test
    func `Overwrite rewrites a file that already carries a date`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dated = folder.appendingPathComponent(Self.datedName)
        let before = try Data(contentsOf: dated)

        let report = await CaptureDateFixer(options: .init(overwrite: true)).fix(folder: folder)

        #expect(Self.shape(report, Self.datedName) == .updated(embedded: true))
        #expect(try Data(contentsOf: dated) != before)
        #expect(ImageDateWriterTests.exifDateTimeOriginal(at: dated) == "2026:08:30 12:34:57")
    }

    @Test
    func `A dry run reports updates without touching any file`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try CaptureDateFixer.candidates(in: folder, recursive: true)
        let before = try files.map { url -> (Data, Date?) in
            try (Data(contentsOf: url), FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }

        let report = await CaptureDateFixer(options: .init(dryRun: true)).fix(folder: folder)

        #expect(Self.shape(report, Self.switchName) == .updated(embedded: true))
        #expect(Self.shape(report, Self.webmName) == .updated(embedded: false))
        #expect(report.updated.count == 3)
        for (url, snapshot) in zip(files, before) {
            #expect(try Data(contentsOf: url) == snapshot.0, "\(url.lastPathComponent) changed")
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            #expect(modified == snapshot.1, "\(url.lastPathComponent) mtime changed")
        }
    }

    @Test
    func `A real run stamps the parsed date onto the Finder dates`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = try #require(FilenameDate.parse(Self.switchName))

        _ = await CaptureDateFixer().fix(folder: folder)

        for name in [Self.switchName, Self.webmName] {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            let created = try #require(attributes[.creationDate] as? Date)
            let modified = try #require(attributes[.modificationDate] as? Date)
            #expect(abs(created.timeIntervalSince(expected)) < 1, "\(name) creation date")
            #expect(abs(modified.timeIntervalSince(expected)) < 1, "\(name) modification date")
        }
    }

    @Test
    func `Non-recursive runs skip subfolders`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let report = await CaptureDateFixer(options: .init(recursive: false)).fix(folder: folder)

        #expect(report.entries.count == Self.candidateCount - 1)
        #expect(!report.entries.contains { $0.url.lastPathComponent == Self.nestedName })
        #expect(try CaptureDateFixer.candidates(in: folder, recursive: false).count == Self.candidateCount - 1)
    }

    @Test
    func `A cancel token fired from onOutcome stops the run after the current file`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = CancelToken()

        let report = await CaptureDateFixer().fix(folder: folder, cancelToken: token, onOutcome: { _ in token.cancel() })

        #expect(report.cancelled)
        #expect(report.entries.count == 1)
    }

    @Test
    func `Progress runs from zero to total over the candidates`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = Mutex<[[Int]]>([])

        let report = await CaptureDateFixer().fix(folder: folder, progress: { done, total in
            progress.withLock { $0.append([done, total]) }
        })

        let calls = progress.withLock { $0 }
        #expect(calls.first == [0, Self.candidateCount])
        #expect(calls.last == [Self.candidateCount, Self.candidateCount])
        #expect(calls.count == 2 * report.entries.count)
    }

    @Test
    func `A path that is not a folder fails as a single entry`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("readme.txt")

        #expect(throws: DateFixError.self) { try CaptureDateFixer.candidates(in: file, recursive: true) }
        let report = await CaptureDateFixer().fix(folder: file)

        #expect(report.entries.count == 1)
        #expect(Self.shape(report, "readme.txt") == .failed)
        let description = try #require(report.failed.first?.1.localizedDescription)
        #expect(description.contains("readme.txt"))
        #expect(!description.contains("error.datefix"))
    }

    @Test
    func `fix(file:) classifies a single file`() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixer = CaptureDateFixer()

        if case .unsupported = await fixer.fix(file: folder.appendingPathComponent("readme.txt")) {} else {
            Issue.record("readme.txt should be unsupported")
        }
        if case .noDateInName = await fixer.fix(file: folder.appendingPathComponent("IMG_notadate.jpg")) {} else {
            Issue.record("IMG_notadate.jpg should have no date")
        }
        if case let .updated(date, embedded) = await fixer.fix(file: folder.appendingPathComponent(Self.switchName)) {
            #expect(embedded)
            #expect(date == FilenameDate.parse(Self.switchName))
        } else {
            Issue.record("\(Self.switchName) should be updated")
        }
    }

    // MARK: - Fixtures

    /// Switch-named JPEG (no EXIF), an already-dated JPEG, a JPEG without a date in its name,
    /// a text file, a WebM, a nested Switch JPEG, a hidden file, and a partial download.
    private static func makeFolder() throws -> URL {
        let folder = try ImageDateWriterTests.makeDirectory()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try ImageDateWriterTests.writeFixture(at: folder.appendingPathComponent(switchName), type: .jpeg)
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2020:01:01 00:00:00"]
        try ImageDateWriterTests.writeFixture(at: folder.appendingPathComponent(datedName), type: .jpeg, properties: [kCGImagePropertyExifDictionary: exif])
        try ImageDateWriterTests.writeFixture(at: folder.appendingPathComponent("IMG_notadate.jpg"), type: .jpeg)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]).write(to: folder.appendingPathComponent(webmName))
        try ImageDateWriterTests.writeFixture(at: folder.appendingPathComponent("nested").appendingPathComponent(nestedName), type: .jpeg)
        try Data([0]).write(to: folder.appendingPathComponent(".DS_Store"))
        try Data([0]).write(to: folder.appendingPathComponent(".x.tethersnap-partial"))
        return folder
    }

    /// The outcome for the entry whose path ends in `suffix`.
    private static func shape(_ report: CaptureDateFixer.Report, _ suffix: String) -> Shape? {
        guard let entry = report.entries.first(where: { $0.url.path.hasSuffix("/" + suffix) }) else { return nil }
        return switch entry.outcome {
        case let .updated(_, embedded): .updated(embedded: embedded)
        case .alreadyDated: .alreadyDated
        case .noDateInName: .noDateInName
        case .unsupported: .unsupported
        case .failed: .failed
        }
    }
}
