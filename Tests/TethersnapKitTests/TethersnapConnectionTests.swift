import Foundation
import Testing
@testable import TethersnapKit

@Suite("Tethersnap connection")
struct TethersnapConnectionTests {
    private func scriptedConnect(_ transport: MockTransport) throws -> TethersnapConnection {
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 0,
            payload: Fixtures.switch2DeviceInfo()
        )
        transport.enqueueResponse(code: .ok, transactionID: 0)
        return try TethersnapConnection(transport: transport, deviceID: .switch2)
    }

    @Test
    func `connect fetches DeviceInfo sessionless before OpenSession, both on transaction 0`() throws {
        let transport = MockTransport()
        let connection = try scriptedConnect(transport)

        #expect(transport.written.count == 2)
        let first = try PTPContainerHeader.decode(transport.written[0])
        let second = try PTPContainerHeader.decode(transport.written[1])
        #expect(first.code == PTPOperationCode.getDeviceInfo.rawValue)
        #expect(first.transactionID == 0)
        #expect(second.code == PTPOperationCode.openSession.rawValue)
        #expect(second.transactionID == 0)
        #expect(connection.cachedDeviceInfo.model == "Nintendo Switch 2")
        #expect(connection.isValid)
    }

    @Test
    func `Handshake falls back to session-first when sessionless GetDeviceInfo is rejected`() throws {
        let transport = MockTransport()
        // Real-device trace (2026-08-30, re-entry into transfer mode): the
        // console answered transaction 0 with an EMPTY data phase and
        // InvalidTransactionID.
        let emptyData = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize),
            type: .data,
            code: PTPOperationCode.getDeviceInfo.rawValue,
            transactionID: 0
        )
        transport.enqueue(emptyData.encoded())
        transport.enqueueResponse(code: .invalidTransactionID, transactionID: 0)
        // Fallback: OpenSession (tx 0), then in-session GetDeviceInfo (tx 1).
        transport.enqueueResponse(code: .ok, transactionID: 0)
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 1,
            payload: Fixtures.switch2DeviceInfo()
        )

        let connection = try TethersnapConnection(transport: transport, deviceID: .switch2)

        #expect(connection.cachedDeviceInfo.model == "Nintendo Switch 2")
        #expect(connection.isValid)
        #expect(transport.written.count == 3)
        let openHeader = try PTPContainerHeader.decode(transport.written[1])
        #expect(openHeader.code == PTPOperationCode.openSession.rawValue)
        let infoHeader = try PTPContainerHeader.decode(transport.written[2])
        #expect(infoHeader.code == PTPOperationCode.getDeviceInfo.rawValue)
        #expect(infoHeader.transactionID == 1)
    }

    @Test
    func `Connect recovers a console stuck with a stale session from another host`() throws {
        let transport = MockTransport()
        // Real-device trace (2026-08-30): another host process left a session
        // open. Sessionless GetDeviceInfo → empty data + InvalidTransactionID;
        // OpenSession → SessionAlreadyOpen; even in-session requests with a
        // fresh counter are InvalidTransactionID, so CloseSession is rejected
        // too and only the class Device Reset clears the responder.
        let emptyData = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize),
            type: .data,
            code: PTPOperationCode.getDeviceInfo.rawValue,
            transactionID: 0
        )
        transport.enqueue(emptyData.encoded())
        transport.enqueueResponse(code: .invalidTransactionID, transactionID: 0)
        transport.enqueueResponse(code: .sessionAlreadyOpen, transactionID: 0) // OpenSession
        transport.enqueueResponse(code: .invalidTransactionID, transactionID: 1) // stale CloseSession
        transport.enqueueResponse(code: .ok, transactionID: 0) // reopen after Device Reset
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 1,
            payload: Fixtures.switch2DeviceInfo()
        )

        let connection = try TethersnapConnection(transport: transport, deviceID: .switch2)

        #expect(connection.cachedDeviceInfo.model == "Nintendo Switch 2")
        #expect(connection.isValid)
        #expect(transport.deviceResetCount == 1)
        let operations = try transport.written.map { try PTPContainerHeader.decode($0).code }
        #expect(operations == [
            PTPOperationCode.getDeviceInfo.rawValue,
            PTPOperationCode.openSession.rawValue,
            PTPOperationCode.closeSession.rawValue,
            PTPOperationCode.openSession.rawValue,
            PTPOperationCode.getDeviceInfo.rawValue,
        ])
    }

    @Test
    func `A connection is a capture source whose descriptor names the model and firmware`() throws {
        let transport = MockTransport()
        let deviceID = USBMTPTransport.DeviceID(vendorID: 0x057E, productID: 0x2061, name: "Nintendo Switch 2", locationID: 0x1420_0000)
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getDeviceInfo.rawValue, transactionID: 0,
            payload: Fixtures.switch2DeviceInfo()
        )
        transport.enqueueResponse(code: .ok, transactionID: 0)
        let connection = try TethersnapConnection(transport: transport, deviceID: deviceID)
        let source: any CaptureSource = connection

        #expect(source.descriptor.id == deviceID.descriptor.id)
        #expect(source.descriptor.name == "Nintendo Switch 2")
        #expect(source.descriptor.detail == "v22.5.0")
        #expect(source.descriptor.kind == .console)
        #expect(source.isValid)

        // Enumeration and download go through the protocol unchanged.
        var storages = PTPDataWriter()
        storages.appendU32Array([0x0001_0001])
        transport.enqueueDataTransaction(operation: PTPOperationCode.getStorageIDs.rawValue, transactionID: 1, payload: storages.data)
        var handles = PTPDataWriter()
        handles.appendU32Array([0x11])
        transport.enqueueDataTransaction(operation: PTPOperationCode.getObjectHandles.rawValue, transactionID: 2, payload: handles.data)
        transport.enqueueDataTransaction(
            operation: PTPOperationCode.getObjectInfo.rawValue, transactionID: 3,
            payload: Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg", size: 2)
        )
        let items = try source.loadItems()
        #expect(items.map(\.filename) == ["2026082917051200-CAFE.jpg"])

        transport.enqueueDataTransaction(operation: PTPOperationCode.getObject.rawValue, transactionID: 4, payload: Data([0xFF, 0xD8]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tethersnap-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try source.download(items[0], to: directory)
        #expect(try Data(contentsOf: result.url) == Data([0xFF, 0xD8]))
    }

    @Test
    func `Capability accessors reflect the Switch 2 profile`() throws {
        let transport = MockTransport()
        let connection = try scriptedConnect(transport)

        #expect(connection.supportsThumbnails) // real console offers GetThumb
        #expect(!connection.supportsPartialObject) // but not GetPartialObject
    }

    @Test
    func `close sends CloseSession and is idempotent`() throws {
        let transport = MockTransport()
        let connection = try scriptedConnect(transport)
        transport.enqueueResponse(code: .ok, transactionID: 1)

        connection.close()
        connection.close()

        #expect(transport.written.count == 3)
        let header = try PTPContainerHeader.decode(#require(transport.written.last))
        #expect(header.code == PTPOperationCode.closeSession.rawValue)
    }

    @Test
    func `A dropped connection still sends CloseSession from deinit`() throws {
        let transport = MockTransport()
        do {
            let connection = try scriptedConnect(transport)
            transport.enqueueResponse(code: .ok, transactionID: 1)
            _ = connection
        }

        let header = try PTPContainerHeader.decode(#require(transport.written.last))
        #expect(header.code == PTPOperationCode.closeSession.rawValue)
    }

    @Test
    func `abandon releases a removed device without CloseSession, and close after it sends nothing`() throws {
        let transport = MockTransport()
        let connection = try scriptedConnect(transport)
        let writtenBefore = transport.written.count

        connection.abandon()
        connection.close()

        #expect(transport.written.count == writtenBefore)
        #expect(!connection.isValid)
    }
}
