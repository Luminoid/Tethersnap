import Foundation
import Testing
@testable import TethersnapKit

@Suite("Clip metadata fix")
struct ClipMetadataFixTests {
    @Test
    func `A clip with a record gets its exact date and camera, then counts as dated`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("C0001.mov")
        try await VideoDateWriterTests.writeMovie(at: clip, fileType: .mov, codec: .jpeg)
        try Data(SonyClipMetadataTests.record.utf8).write(to: directory.appendingPathComponent("C0001M01.XML"))
        let fixer = CaptureDateFixer()

        let first = await fixer.fix(folder: directory)

        #expect(first.entries.map(\.url.lastPathComponent) == ["C0001.mov"]) // the record itself is not a candidate
        guard case let .updated(date, embedded) = try #require(first.entries.first?.outcome) else {
            Issue.record("expected an update, got \(String(describing: first.entries.first?.outcome))")
            return
        }
        #expect(date == MovieMetadataPatcherTests.date)
        #expect(embedded)
        #expect(try await VideoDateWriter.embeddedMake(at: clip) == "Sony")
        let readBack = try #require(try await VideoDateWriter.embeddedDate(at: clip))
        #expect(abs(readBack.timeIntervalSince(MovieMetadataPatcherTests.date)) < 1)
        let modified = try #require(try clip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(abs(modified.timeIntervalSince(MovieMetadataPatcherTests.date)) < 1)

        let second = await fixer.fix(folder: directory)

        #expect(second.alreadyDated.map(\.lastPathComponent) == ["C0001.mov"])
    }

    @Test
    func `A clip patched before its record had a position is updated once more, then left alone`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("C0002.mov")
        try await VideoDateWriterTests.writeMovie(at: clip, fileType: .mov, codec: .jpeg)
        let sidecar = directory.appendingPathComponent("C0002M01.XML")
        try Data(SonyClipMetadataTests.record.utf8).write(to: sidecar)
        let fixer = CaptureDateFixer()
        _ = await fixer.fix(folder: directory)
        #expect(try await VideoDateWriter.embeddedLocation(at: clip) == nil)

        try Data(SonyClipMetadataTests.locatedRecord.utf8).write(to: sidecar)
        let withPosition = await fixer.fix(folder: directory)
        let again = await fixer.fix(folder: directory)

        #expect(withPosition.updated.map(\.lastPathComponent) == ["C0002.mov"])
        #expect(try await VideoDateWriter.embeddedLocation(at: clip) == "+37.4156-121.9579/")
        #expect(again.alreadyDated.map(\.lastPathComponent) == ["C0002.mov"])
    }

    @Test
    func `With the record turned off, a clip is handled by its filename alone`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("C0001.mov")
        try await VideoDateWriterTests.writeMovie(at: clip, fileType: .mov, codec: .jpeg)
        try Data(SonyClipMetadataTests.record.utf8).write(to: directory.appendingPathComponent("C0001M01.XML"))
        let before = try Data(contentsOf: clip)

        let report = await CaptureDateFixer(options: .init(clipMetadata: false)).fix(folder: directory)

        #expect(report.noDateInName.map(\.lastPathComponent) == ["C0001.mov"])
        #expect(report.entries.count == 1)
        #expect(try Data(contentsOf: clip) == before)
    }
}
