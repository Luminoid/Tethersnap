import Foundation
import Testing
@testable import TethersnapKit

/// Framing edge cases driven straight into the reader, which is internal for
/// exactly this purpose: no session scripting needed.
@Suite("PTP container reader")
struct PTPContainerReaderTests {
    private static let chunkSize = 16

    private func dataHeader(length: UInt32) -> Data {
        PTPContainerHeader(length: length, type: .data, code: PTPOperationCode.getObject.rawValue, transactionID: 1).encoded()
    }

    private func response() -> Data {
        PTPContainerHeader(length: 12, type: .response, code: PTPResponseCode.ok.rawValue, transactionID: 1).encoded()
    }

    @Test
    func `An unknown-length data phase streams until a transfer shorter than requested`() throws {
        let transport = MockTransport()
        transport.enqueue(
            dataHeader(length: PTPContainerReader.unknownLength) + Data(repeating: 0xA1, count: 4), // exactly one chunk
            Data(repeating: 0xA2, count: Self.chunkSize),
            Data(repeating: 0xA3, count: 5), // short: the phase ends here
            response()
        )
        var reader = PTPContainerReader(transport: transport, chunkSize: Self.chunkSize, timeout: 1)
        var collected = Data()

        let (header, payload) = try reader.next(dataSink: { collected.append($0) }, responseTimeout: 1)
        let (next, _) = try reader.next(dataSink: nil, responseTimeout: 1)

        #expect(header.type == .data)
        #expect(payload.isEmpty)
        #expect(collected == Data(repeating: 0xA1, count: 4) + Data(repeating: 0xA2, count: Self.chunkSize) + Data(repeating: 0xA3, count: 5))
        #expect(next.type == .response)
    }

    @Test
    func `A zero-length packet ends an unknown-length data phase whose size was a packet multiple`() throws {
        let transport = MockTransport()
        transport.enqueue(
            dataHeader(length: PTPContainerReader.unknownLength) + Data(repeating: 0xB1, count: 4),
            Data(repeating: 0xB2, count: Self.chunkSize),
            Data(),
            response()
        )
        var reader = PTPContainerReader(transport: transport, chunkSize: Self.chunkSize, timeout: 1)
        var collected = Data()

        _ = try reader.next(dataSink: { collected.append($0) }, responseTimeout: 1)
        let (next, _) = try reader.next(dataSink: nil, responseTimeout: 1)

        #expect(collected.count == 4 + Self.chunkSize)
        #expect(next.type == .response)
    }

    @Test
    func `A known-length data phase gives up after three zero-length reads instead of spinning`() throws {
        let transport = MockTransport()
        transport.enqueue(dataHeader(length: 12 + 8), Data(), Data(), Data(), Data(), Data())
        var reader = PTPContainerReader(transport: transport, chunkSize: Self.chunkSize, timeout: 1)

        #expect {
            try reader.next(dataSink: { _ in }, responseTimeout: 1)
        } throws: { error in
            if case MTPError.malformedData = error { true } else { false }
        }
    }

    @Test
    func `A data phase nobody asked for is consumed and dropped`() throws {
        let transport = MockTransport()
        transport.enqueue(dataHeader(length: 12 + 4) + Data([1, 2, 3, 4]), response())
        var reader = PTPContainerReader(transport: transport, chunkSize: Self.chunkSize, timeout: 1)

        let (stray, payload) = try reader.next(dataSink: nil, responseTimeout: 1)
        let (next, _) = try reader.next(dataSink: nil, responseTimeout: 1)

        #expect(stray.type == .data)
        #expect(payload.isEmpty)
        #expect(next.type == .response)
    }

    @Test
    func `A UInt16 array whose count exceeds the payload is rejected up front`() {
        var writer = PTPDataWriter()
        writer.appendU32(0xFFFF) // claims 65535 entries
        writer.appendU16(1)
        var reader = PTPDataReader(writer.data)

        #expect(throws: MTPError.self) { _ = try reader.readU16Array() }
    }
}
