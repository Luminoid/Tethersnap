import Foundation
import Testing
@testable import TethersnapKit

/// What `CaptureLibrary.loadItems` does when the responder misbehaves
/// mid-enumeration: skip what it can, never pass a truncated list for a
/// complete one, and never let a degenerate filename reach the disk layer.
@Suite("Capture library resilience")
struct CaptureLibraryResilienceTests {
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

    private func enqueueObjectInfo(_ transport: MockTransport, transactionID: UInt32, _ payload: Data) {
        transport.enqueueDataTransaction(operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: transactionID, payload: payload)
    }

    @Test
    func `A transport failure mid-enumeration throws instead of returning a truncated list`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 2, values: [1, 2, 3])
        enqueueObjectInfo(transport, transactionID: 3, Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg"))
        // The cable goes at object 2: the mock has nothing more to deliver.

        #expect(throws: MTPError.self) {
            try CaptureLibrary(session: session).loadItems()
        }
        #expect(!session.isValid)
    }

    @Test
    func `A rejected sub-folder costs its own contents, not the whole storage`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        transport.enqueueResponse(code: .parameterNotSupported, transactionID: 2) // flat query rejected
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 3, values: [0x10, 0x20])
        enqueueObjectInfo(transport, transactionID: 4, Fixtures.objectInfo(filename: "Deleted Game", format: PTPObjectFormat.association))
        transport.enqueueResponse(code: .invalidObjectHandle, transactionID: 5) // its listing is refused
        enqueueObjectInfo(transport, transactionID: 6, Fixtures.objectInfo(filename: "Other Game", format: PTPObjectFormat.association))
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 7, values: [0x21])
        enqueueObjectInfo(transport, transactionID: 8, Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg"))

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.map(\.filename) == ["2026082917051200-CAFE.jpg"])
        #expect(items.first?.folderName == "Other Game")
    }

    @Test
    func `A folder that lists itself is walked once`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        transport.enqueueResponse(code: .parameterNotSupported, transactionID: 2)
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 3, values: [0x10])
        enqueueObjectInfo(transport, transactionID: 4, Fixtures.objectInfo(filename: "Loop", format: PTPObjectFormat.association))
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 5, values: [0x10, 0x11]) // contains itself
        enqueueObjectInfo(transport, transactionID: 6, Fixtures.objectInfo(filename: "Loop", format: PTPObjectFormat.association))
        enqueueObjectInfo(transport, transactionID: 7, Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg"))

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.map(\.filename) == ["2026082917051200-CAFE.jpg"])
        let listings = try transport.written.map { try PTPContainerHeader.decode($0) }.filter { $0.code == PTPOperationCode.getObjectHandles.rawValue }
        #expect(listings.count == 3) // flat attempt, root, Loop; never Loop again
    }

    @Test
    func `Degenerate reported filenames become handle-based names that stay inside the export folder`() throws {
        let transport = MockTransport()
        let session = try makeOpenSession(transport)
        enqueueU32Array(transport, operation: .getStorageIDs, transactionID: 1, values: [0x0001_0001])
        enqueueU32Array(transport, operation: .getObjectHandles, transactionID: 2, values: [7, 8, 9])
        enqueueObjectInfo(transport, transactionID: 3, Fixtures.objectInfo(filename: ""))
        enqueueObjectInfo(transport, transactionID: 4, Fixtures.objectInfo(filename: "..", format: 0xB982))
        enqueueObjectInfo(transport, transactionID: 5, Fixtures.objectInfo(filename: "sub/shot.jpg"))

        let items = try CaptureLibrary(session: session).loadItems()

        #expect(items.map(\.filename) == ["00000007.jpg", "00000008.mp4", "00000009.jpg"])
        #expect(items.map(\.kind) == [.image, .video, .image])
        #expect(items.allSatisfy { DownloadWriter.isUsableFilename($0.exportFilename) })
    }
}
