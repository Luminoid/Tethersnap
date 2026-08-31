import Foundation
import Testing
@testable import TethersnapKit

@Suite("Robustness")
struct RobustnessTests {
    @Test
    func `GetThumb streams the device thumbnail through the same engine`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let body = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let header = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + body.count),
            type: .data,
            code: PTPOperationCode.getThumb.rawValue,
            transactionID: 1
        )
        transport.enqueue(header.encoded() + body)
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        var received = Data()
        try session.thumb(for: 0x42, sink: { received.append($0) })

        #expect(received == body)
        let command = try PTPContainerHeader.decode(#require(transport.written.last))
        #expect(command.code == PTPOperationCode.getThumb.rawValue)
    }

    @Test
    func `ObjectInfo thumbnail size flows into CaptureItem`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        var storages = PTPDataWriter()
        storages.appendU32Array([0x0001_0001])
        transport.enqueueDataTransaction(operation: PTPOperationCode.getStorageIDs.rawValue, transactionID: 1, payload: storages.data)
        var handles = PTPDataWriter()
        handles.appendU32Array([7])
        transport.enqueueDataTransaction(operation: PTPOperationCode.getObjectHandles.rawValue, transactionID: 2, payload: handles.data)
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 3,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg", thumbSize: 12345)
        )
        let session = MTPSession(transport: transport)
        try session.open()

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.first?.thumbSizeInBytes == 12345)
    }

    @Test
    func `A cancelled download removes the partial file and throws CancellationError`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let body = Data(repeating: 0xAB, count: 4096)
        let header = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + body.count),
            type: .data,
            code: PTPOperationCode.getObject.rawValue,
            transactionID: 1
        )
        transport.enqueue(header.encoded() + body)
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()
        let item = CaptureItem(handle: 1, storageID: 1, filename: "shot.jpg", kind: .screenshot, sizeInBytes: 4096, date: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = CancelToken()
        token.cancel()

        #expect(throws: CancellationError.self) {
            try CaptureLibrary(session: session).download(item, to: directory, cancelToken: token)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test
    func `An implausible buffered container length is rejected instead of allocated`() throws {
        let transport = MockTransport()
        var writer = PTPDataWriter()
        writer.appendU32(0xF000_0000) // ~3.75 GB response container
        writer.appendU16(PTPContainerType.response.rawValue)
        writer.appendU16(PTPResponseCode.ok.rawValue)
        writer.appendU32(0)
        transport.enqueue(writer.data)
        let session = MTPSession(transport: transport)

        #expect(throws: MTPError.self) { try session.open() }
    }

    @Test
    func `CancelToken is a plain thread-safe flag`() {
        let token = CancelToken()

        #expect(!token.isCancelled)
        token.cancel()
        #expect(token.isCancelled)
    }

    @Test
    func `File logging writes timestamped debug lines and rotates the previous run`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-log-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("Tethersnap.log")
        defer {
            TethersnapLog.disableFileLogging()
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(TethersnapLog.enableFileLogging(at: url) != nil)
        TethersnapLog.info(TethersnapLog.app, "first-run marker")
        TethersnapLog.debug(TethersnapLog.usb, "debug marker reaches the file sink")
        TethersnapLog.disableFileLogging()
        let firstRun = try String(contentsOf: url, encoding: .utf8)
        #expect(firstRun.contains("[info] app: first-run marker"))
        #expect(firstRun.contains("[debug] usb: debug marker reaches the file sink"))

        #expect(TethersnapLog.enableFileLogging(at: url) != nil)
        TethersnapLog.disableFileLogging()
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
        let rotated = try String(contentsOf: previous, encoding: .utf8)
        #expect(rotated.contains("first-run marker"))
    }
}
