import Foundation
import Testing
@testable import TethersnapKit

@Suite("Capture library")
struct CaptureLibraryTests {
    private func makeOpenSession(_ transport: MockTransport) throws -> MTPSession {
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let session = MTPSession(transport: transport)
        try session.open()
        return session
    }

    private func enqueueU32Array(_ transport: MockTransport, operation: PTPOperationCode, transactionID: UInt32, values: [UInt32]) {
        var payload = PTPDataWriter()
        payload.appendU32Array(values)
        transport.enqueueDataTransaction(operation: operation.rawValue, transactionID: transactionID, payload: payload.data)
    }

    @Test
    func `loadItems keeps captures and filters folders and foreign files`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 2, values: [1, 2, 3, 4])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 3,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg")
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 4,
            payload: Fixtures.objectInfo(filename: "2026010109300000-BEEF.mp4", size: 9_000_000, captureDate: "")
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 5,
            payload: Fixtures.objectInfo(filename: "Album", format: PTPObjectFormat.association)
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 6,
            payload: Fixtures.objectInfo(filename: "system.bin")
        )

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.count == 2)
        #expect(items[0].filename == "2026082917051200-CAFE.jpg")
        #expect(items[0].kind == .screenshot)
        #expect(items[1].filename == "2026010109300000-BEEF.mp4")
        #expect(items[1].kind == .video)
        #expect(items[1].sizeInBytes == 9_000_000)
    }

    @Test
    func `loadItems falls back to a recursive walk when the flat query is rejected`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        transport.enqueueResponse(code: .parameterNotSupported, transactionID: 2)
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 3, values: [0x10])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 4,
            payload: Fixtures.objectInfo(filename: "Album", format: PTPObjectFormat.association)
        )
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 5, values: [0x11])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 6,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg")
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 7,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg")
        )

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.map(\.filename) == ["2026082917051200-CAFE.jpg"])
        #expect(items.map(\.folderName) == ["Album"])
    }

    @Test
    func `The recursive walk records each capture's game folder`() throws {
        // Real console layout: root associations are per-game folders holding
        // the captures directly.
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        transport.enqueueResponse(code: .invalidObjectHandle, transactionID: 2) // flat query rejected
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 3, values: [0x10, 0x20])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 4,
            payload: Fixtures.objectInfo(filename: "Mario Kart World", format: PTPObjectFormat.association)
        )
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 5, values: [0x11])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 6,
            payload: Fixtures.objectInfo(filename: "2026082917051200_c.jpg")
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 7,
            payload: Fixtures.objectInfo(filename: "Zelda", format: PTPObjectFormat.association)
        )
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 8, values: [0x21])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 9,
            payload: Fixtures.objectInfo(filename: "2026083010000000_c.mp4", size: 5_000_000)
        )

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.map(\.folderName) == ["Mario Kart World", "Zelda"])
        #expect(items.map(\.kind) == [.screenshot, .video])
    }

    @Test
    func `download streams a capture to disk and stamps the capture date`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        let body = Data((0 ..< 2048).map { UInt8($0 % 200) })
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + body.count),
            type: .data,
            code: PTPOperationCode.getObject.rawValue,
            transactionID: 1
        )
        transport.enqueue(dataHeader.encoded() + body)
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let item = CaptureItem(handle: 0x42, storageID: 1, filename: "shot.jpg", kind: .screenshot, sizeInBytes: Int64(body.count), date: date)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try CaptureLibrary(session: session).download(item, to: directory)
        let destination = result.url

        #expect(!result.skippedExisting)
        #expect(try Data(contentsOf: destination) == body)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let modification = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modification.timeIntervalSince(date)) < 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["shot.jpg"])
    }

    @Test
    func `download with skipExisting leaves a same-size existing file untouched`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        let item = CaptureItem(handle: 0x42, storageID: 1, filename: "shot.jpg", kind: .screenshot, sizeInBytes: 4, date: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("shot.jpg")
        try Data([0xAA, 0xBB, 0xCC, 0xDD]).write(to: existing)

        let result = try CaptureLibrary(session: session).download(item, to: directory, skipExisting: true)

        #expect(result.skippedExisting)
        #expect(try Data(contentsOf: existing) == Data([0xAA, 0xBB, 0xCC, 0xDD]))
        #expect(transport.written.count == 1) // just the OpenSession command
    }

    @Test
    func `download with skipExisting re-fetches when the existing size differs`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        let body = Data([0x01, 0x02, 0x03, 0x04])
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + body.count),
            type: .data,
            code: PTPOperationCode.getObject.rawValue,
            transactionID: 1
        )
        transport.enqueue(dataHeader.encoded() + body)
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let item = CaptureItem(handle: 0x42, storageID: 1, filename: "shot.jpg", kind: .screenshot, sizeInBytes: 4, date: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("shot.jpg")
        try Data([0xAA]).write(to: existing) // truncated leftover from an interrupted run

        let result = try CaptureLibrary(session: session).download(item, to: directory, skipExisting: true)

        #expect(!result.skippedExisting)
        #expect(try Data(contentsOf: existing) == body)
    }

    @Test
    func `A transfer failure mid-download removes the partial file`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + 4096),
            type: .data,
            code: PTPOperationCode.getObject.rawValue,
            transactionID: 1
        )
        // Promise 4096 bytes, deliver 1000, then the transport dies.
        transport.enqueue(dataHeader.encoded() + Data(repeating: 0xCD, count: 1000))
        let item = CaptureItem(handle: 1, storageID: 1, filename: "shot.jpg", kind: .screenshot, sizeInBytes: 4096, date: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: MTPError.self) {
            try CaptureLibrary(session: session).download(item, to: directory)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(!session.isValid) // abandoned data phase invalidates the session
    }

    @Test
    func `A single malformed ObjectInfo is skipped instead of failing the whole enumeration`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 2, values: [1, 2, 3])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 3,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg")
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 4,
            payload: Data([0x01, 0x02]) // truncated dataset
        )
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 5,
            payload: Fixtures.objectInfo(filename: "2026010109300000-BEEF.mp4")
        )

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.map(\.filename) == ["2026082917051200-CAFE.jpg", "2026010109300000-BEEF.mp4"])
    }

    @Test
    func `Cross-storage filename collisions get numbered export filenames`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001, 0x0002_0001])
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 2, values: [1])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 3,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg")
        )
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 4, values: [2])
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 5,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg", storageID: 0x0002_0001)
        )

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.count == 2)
        #expect(items[0].exportFilename == "2026082917051200-CAFE.jpg")
        #expect(items[1].exportFilename == "2026082917051200-CAFE-2.jpg")
        #expect(items[1].filename == "2026082917051200-CAFE.jpg")
    }

    @Test
    func `thumbnailPayload prefers GetThumb, falls back to a partial prefix, and skips videos`() throws {
        // Device thumbnail available: GetThumb wins and the payload is complete.
        let thumbTransport = MockTransport()
        let thumbSession = try makeOpenSession(thumbTransport)
        thumbTransport.enqueueDataTransaction(
            operation: PTPOperationCode.getThumb.rawValue, transactionID: 1, payload: Data([0xFF, 0xD8])
        )
        let thumbItem = CaptureItem(handle: 1, storageID: 1, filename: "a.jpg", kind: .screenshot, sizeInBytes: 9999, thumbSizeInBytes: 2, date: nil)
        let thumb = try #require(try CaptureLibrary(session: thumbSession).thumbnailPayload(
            for: thumbItem, deviceOffersThumbnails: true, deviceOffersPartialObject: true
        ))
        #expect(thumb.data == Data([0xFF, 0xD8]))
        #expect(thumb.isComplete)

        // No GetThumb: a screenshot uses a bounded GetPartialObject prefix.
        let prefixTransport = MockTransport()
        let prefixSession = try makeOpenSession(prefixTransport)
        prefixTransport.enqueueDataTransaction(
            operation: PTPOperationCode.getPartialObject.rawValue, transactionID: 1, payload: Data(repeating: 0xEE, count: 100)
        )
        let shot = CaptureItem(handle: 2, storageID: 1, filename: "b.jpg", kind: .screenshot, sizeInBytes: 999_999, date: nil)
        let prefix = try #require(try CaptureLibrary(session: prefixSession).thumbnailPayload(
            for: shot, deviceOffersThumbnails: false, deviceOffersPartialObject: true
        ))
        #expect(prefix.data.count == 100)
        #expect(!prefix.isComplete)
        let command = try PTPContainerHeader.decode(#require(prefixTransport.written.last))
        #expect(command.code == PTPOperationCode.getPartialObject.rawValue)

        // A video without a device thumbnail has no cheap preview.
        let videoTransport = MockTransport()
        let videoSession = try makeOpenSession(videoTransport)
        let video = CaptureItem(handle: 3, storageID: 1, filename: "c.mp4", kind: .video, sizeInBytes: 5_000_000, date: nil)
        let videoPayload = try CaptureLibrary(session: videoSession).thumbnailPayload(
            for: video, deviceOffersThumbnails: false, deviceOffersPartialObject: true
        )
        #expect(videoPayload == nil)
        #expect(videoTransport.written.count == 1) // just OpenSession; no wire traffic for the video
    }
}
