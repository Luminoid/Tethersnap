import Foundation
import Testing
@testable import TethersnapKit

@Suite("MTP session")
struct MTPSessionTests {
    @Test
    func `OpenSession uses transaction ID 0 and session ID 1`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let session = MTPSession(transport: transport)

        try session.open()

        let command = try #require(transport.written.first)
        let header = try PTPContainerHeader.decode(command)
        #expect(header.type == .command)
        #expect(header.code == PTPOperationCode.openSession.rawValue)
        #expect(header.transactionID == 0)
        #expect([UInt8](command[12 ..< 16]) == [1, 0, 0, 0])
    }

    @Test
    func `A stale session is closed and reopened, not resumed`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .sessionAlreadyOpen, transactionID: 0)
        transport.enqueueResponse(code: .ok, transactionID: 1) // CloseSession accepted
        transport.enqueueResponse(code: .ok, transactionID: 0) // reopen
        let session = MTPSession(transport: transport)

        try session.open()

        let operations = try transport.written.map { try PTPContainerHeader.decode($0).code }
        #expect(operations == [
            PTPOperationCode.openSession.rawValue,
            PTPOperationCode.closeSession.rawValue,
            PTPOperationCode.openSession.rawValue,
        ])
        #expect(transport.deviceResetCount == 0)
    }

    @Test
    func `A stale session that rejects CloseSession gets a class Device Reset before the reopen`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .sessionAlreadyOpen, transactionID: 0)
        transport.enqueueResponse(code: .invalidTransactionID, transactionID: 1) // stale counter rejects the close too
        transport.enqueueResponse(code: .ok, transactionID: 0) // reopen after the reset
        let session = MTPSession(transport: transport)

        try session.open()

        #expect(transport.deviceResetCount == 1)
        #expect(session.isValid)
    }

    @Test
    func `A console that STALLs the Device Reset gets a USB re-enumeration`() {
        // Real trace (2026-08-30): Android File Transfer Agent left a stale
        // session, the console rejected CloseSession AND stalled the class
        // Device Reset. The only way out is the software replug.
        let transport = MockTransport()
        transport.enqueueResponse(code: .sessionAlreadyOpen, transactionID: 0)
        transport.enqueueResponse(code: .invalidTransactionID, transactionID: 1)
        transport.deviceResetError = MTPError.transferFailed(underlying: NSError(domain: "test", code: 1))
        let session = MTPSession(transport: transport)

        #expect(performing: { try session.open() }, throws: { error in
            if case MTPError.staleSessionReset = error { return true }
            return false
        })
        #expect(transport.hardResetCount == 1)
        #expect(!session.isValid)
    }

    @Test
    func `Non-OK responses surface as deviceResponse errors`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueResponse(code: .invalidObjectHandle, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(throws: MTPError.self) { _ = try session.objectInfo(for: 99) }
    }

    @Test
    func `GetObjectHandles decodes the handle array from the data phase`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        var payload = PTPDataWriter()
        payload.appendU32Array([0x11, 0x22, 0x33])
        transport.enqueueDataTransaction(operation: PTPOperationCode.getObjectHandles.rawValue, transactionID: 1, payload: payload.data)
        let session = MTPSession(transport: transport)
        try session.open()

        let handles = try session.objectHandles(storageID: 0x0001_0001, parent: nil)

        #expect(handles == [0x11, 0x22, 0x33])
        let command = try #require(transport.written.last)
        let header = try PTPContainerHeader.decode(command)
        #expect(header.code == PTPOperationCode.getObjectHandles.rawValue)
        #expect(command.count == 24) // three parameters
    }

    @Test
    func `DeviceInfo runs sessionless with transaction ID 0`() throws {
        let transport = MockTransport()
        transport.enqueueDataTransaction(operation: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 0, payload: Fixtures.switch2DeviceInfo())
        let session = MTPSession(transport: transport)

        let info = try session.deviceInfo()

        #expect(info.model == "Nintendo Switch 2")
        let header = try PTPContainerHeader.decode(#require(transport.written.first))
        #expect(header.transactionID == 0)
    }

    @Test
    func `A header split across two transfers is reassembled`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        var payload = PTPDataWriter()
        payload.appendU32Array([0x7A])
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + payload.data.count),
            type: .data,
            code: PTPOperationCode.getObjectHandles.rawValue,
            transactionID: 1
        )
        let whole = dataHeader.encoded() + payload.data
        transport.enqueue(whole.prefix(5), whole.suffix(from: 5))
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(try session.objectHandles(parent: nil) == [0x7A])
    }

    @Test
    func `A data container and its response coalesced into one transfer both parse`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        var payload = PTPDataWriter()
        payload.appendU32Array([0x5A])
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + payload.data.count),
            type: .data,
            code: PTPOperationCode.getObjectHandles.rawValue,
            transactionID: 1
        )
        let response = PTPContainerHeader(length: 12, type: .response, code: PTPResponseCode.ok.rawValue, transactionID: 1)
        transport.enqueue(dataHeader.encoded() + payload.data + response.encoded())
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(try session.objectHandles(parent: nil) == [0x5A])
    }

    @Test
    func `Stray zero-length packets between containers are tolerated`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        var payload = PTPDataWriter()
        payload.appendU32Array([0x99])
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + payload.data.count),
            type: .data,
            code: PTPOperationCode.getObjectHandles.rawValue,
            transactionID: 1
        )
        transport.enqueue(dataHeader.encoded() + payload.data, Data())
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(try session.objectHandles(parent: nil) == [0x99])
    }

    @Test
    func `A response for a different transaction throws transactionMismatch`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueResponse(code: .ok, transactionID: 42)
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(throws: MTPError.self) { _ = try session.storageIDs() }
    }

    @Test
    func `close sends CloseSession once and is idempotent`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        session.close()
        session.close()

        #expect(transport.written.count == 2)
        let header = try PTPContainerHeader.decode(#require(transport.written.last))
        #expect(header.code == PTPOperationCode.closeSession.rawValue)
    }

    @Test
    func `close swallows a failing CloseSession instead of throwing`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueResponse(code: .generalError, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        session.close() // must not throw or crash
    }

    @Test
    func `A transport failure invalidates the session and later transactions are refused`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let session = MTPSession(transport: transport)
        try session.open()
        #expect(session.isValid)

        // No scripted response: the transport dies mid-transaction.
        #expect(throws: MTPError.self) { _ = try session.storageIDs() }
        #expect(!session.isValid)

        do {
            _ = try session.storageIDs()
            Issue.record("an invalidated session must refuse transactions")
        } catch MTPError.sessionInvalidated {
            // expected
        } catch {
            Issue.record("expected sessionInvalidated, got \(error)")
        }
    }

    @Test
    func `A non-OK device response does not invalidate the session`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueResponse(code: .invalidObjectHandle, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(throws: MTPError.self) { _ = try session.objectInfo(for: 99) }
        #expect(session.isValid)
    }

    @Test
    func `A flood of stray event containers aborts instead of looping forever`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        for _ in 0 ..< 9 {
            let event = PTPContainerHeader(length: 12, type: .event, code: 0x4002, transactionID: 1)
            transport.enqueue(event.encoded())
        }
        let session = MTPSession(transport: transport)
        try session.open()

        #expect(throws: MTPError.self) { _ = try session.storageIDs() }
    }

    @Test
    func `GetPartialObject sends handle, offset, and maxBytes and returns the prefix`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let body = Data(repeating: 0x5C, count: 64)
        transport.enqueueDataTransaction(operation: PTPOperationCode.getPartialObject.rawValue, transactionID: 1, payload: body)
        let session = MTPSession(transport: transport)
        try session.open()

        let prefix = try session.partialObject(for: 0x42, maxBytes: 100)

        #expect(prefix == body)
        let command = try #require(transport.written.last)
        let header = try PTPContainerHeader.decode(command)
        #expect(header.code == PTPOperationCode.getPartialObject.rawValue)
        #expect(command.count == 24) // three parameters
        #expect([UInt8](command[12 ..< 16]) == [0x42, 0, 0, 0]) // handle
        #expect([UInt8](command[16 ..< 20]) == [0, 0, 0, 0]) // offset
        #expect([UInt8](command[20 ..< 24]) == [100, 0, 0, 0]) // maxBytes
    }

    @Test
    func `StorageInfo decodes through a session transaction`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueDataTransaction(operation: PTPOperationCode.getStorageInfo.rawValue, transactionID: 1, payload: Fixtures.storageInfo())
        let session = MTPSession(transport: transport)
        try session.open()

        let info = try session.storageInfo(for: 0x0001_0001)

        #expect(info.displayName == "Album")
    }

    @Test
    func `GetObject streams the payload to the sink across chunked transfers`() throws {
        let transport = MockTransport()
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let body = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + body.count),
            type: .data,
            code: PTPOperationCode.getObject.rawValue,
            transactionID: 1
        )
        transport.enqueue(dataHeader.encoded() + body.prefix(1000), body.suffix(4000))
        transport.enqueueResponse(code: .ok, transactionID: 1)
        let session = MTPSession(transport: transport)
        try session.open()

        var received = Data()
        var lastProgress: Int64 = 0
        try session.object(for: 0x42, sink: { received.append($0) }, progress: { lastProgress = $0 })

        #expect(received == body)
        #expect(lastProgress == Int64(body.count))
    }
}
