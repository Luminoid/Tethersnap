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
        #expect(connection.isSessionValid)
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
        #expect(connection.isSessionValid)
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
        #expect(connection.isSessionValid)
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
}
