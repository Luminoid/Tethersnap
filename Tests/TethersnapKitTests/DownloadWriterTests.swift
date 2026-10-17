import Foundation
import Testing
@testable import TethersnapKit

@Suite("Download writer")
struct DownloadWriterTests {
    private struct ProducerFailure: Error {}

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeItem(size: Int64, date: Date? = nil) -> CaptureItem {
        CaptureItem(origin: .file(URL(fileURLWithPath: "/dev/null")), filename: "shot.jpg", kind: .image, sizeInBytes: size, date: date)
    }

    @Test
    func `A cancellation mid-stream leaves no partial file`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = CancelToken()

        #expect(throws: CancellationError.self) {
            try DownloadWriter.write(makeItem(size: 4), to: directory, skipExisting: false, cancelToken: token, progress: nil) { sink in
                try sink(Data([1, 2]))
                token.cancel()
                try sink(Data([3, 4]))
            }
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test
    func `A producer failure removes the partial file`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ProducerFailure.self) {
            try DownloadWriter.write(makeItem(size: 4), to: directory, skipExisting: false, cancelToken: nil, progress: nil) { sink in
                try sink(Data([1, 2]))
                throw ProducerFailure()
            }
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test
    func `Progress counts written bytes and the date lands on the file`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var reports: [(Int64, Int64)] = []

        let result = try DownloadWriter.write(
            makeItem(size: 4, date: date), to: directory, skipExisting: false, cancelToken: nil,
            progress: { reports.append(($0, $1)) },
            producer: { sink in
                try sink(Data([1, 2]))
                try sink(Data([3, 4]))
            }
        )

        #expect(!result.skippedExisting)
        #expect(reports.map(\.0) == [2, 4])
        #expect(reports.map(\.1) == [4, 4])
        #expect(try Data(contentsOf: result.url) == Data([1, 2, 3, 4]))
        let modification = try #require(FileManager.default.attributesOfItem(atPath: result.url.path)[.modificationDate] as? Date)
        #expect(abs(modification.timeIntervalSince(date)) < 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["shot.jpg"])
    }

    @Test
    func `An item of unknown size skips on existence alone`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0xAA]).write(to: directory.appendingPathComponent("shot.jpg"))
        var produced = false

        // The 0xFFFFFFFF sentinel is a PTP convention: only a PTP item skips on existence.
        let ptpItem = CaptureItem(handle: 1, storageID: 0x0001_0001, filename: "shot.jpg", kind: .image, sizeInBytes: Int64(UInt32.max), date: nil)
        let result = try DownloadWriter.write(ptpItem, to: directory, skipExisting: true, cancelToken: nil, progress: nil) { _ in
            produced = true
        }

        #expect(result.skippedExisting)
        #expect(!produced)

        // A file-backed item of that size has an exact size, so the 1-byte copy is stale.
        let fileResult = try DownloadWriter.write(makeItem(size: Int64(UInt32.max)), to: directory, skipExisting: true, cancelToken: nil, progress: nil) { sink in
            try sink(Data([0xBB]))
        }
        #expect(!fileResult.skippedExisting)
    }

    @Test
    func `A degenerate filename is refused before any disk access`() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x01]).write(to: directory.appendingPathComponent("keep.jpg"))

        for name in ["", ".", "..", "sub/shot.jpg"] {
            var item = CaptureItem(handle: 2, storageID: 0x0001_0001, filename: name, kind: .image, sizeInBytes: 1, date: nil)
            item.exportFilename = name
            var produced = false
            #expect(throws: CaptureSourceError.self, "\(name.debugDescription) must be refused") {
                try DownloadWriter.write(item, to: directory, skipExisting: false, cancelToken: nil, progress: nil) { _ in
                    produced = true
                }
            }
            #expect(!produced)
        }
        // The export folder and its contents survive every attempt.
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep.jpg").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["keep.jpg"])
    }
}
