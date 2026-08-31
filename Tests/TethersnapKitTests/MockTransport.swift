import Foundation
@testable import TethersnapKit

/// Scripted transport: queues canned bulk-in transfers and records bulk-out
/// writes, so `MTPSession` can be exercised without hardware.
final class MockTransport: MTPTransport {
    private(set) var written: [Data] = []
    private(set) var deviceResetCount = 0
    private(set) var hardResetCount = 0
    /// When set, `deviceReset()` throws it (the real console STALLs the request).
    var deviceResetError: Error?
    private var inbound: [Data]

    /// Each element is one bulk-in transfer, returned verbatim (regardless of
    /// the requested length) to simulate coalescing, splits, and ZLPs.
    init(inbound: [Data] = []) {
        self.inbound = inbound
    }

    func enqueue(_ transfers: Data...) {
        inbound.append(contentsOf: transfers)
    }

    /// Queue a data container + OK response for the next transaction.
    func enqueueDataTransaction(operation: UInt16, transactionID: UInt32, payload: Data) {
        let dataHeader = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + payload.count),
            type: .data,
            code: operation,
            transactionID: transactionID
        )
        enqueue(dataHeader.encoded() + payload)
        enqueueResponse(code: .ok, transactionID: transactionID)
    }

    func enqueueResponse(code: PTPResponseCode, transactionID: UInt32, parameters: [UInt32] = []) {
        let header = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + parameters.count * 4),
            type: .response,
            code: code.rawValue,
            transactionID: transactionID
        )
        var writer = PTPDataWriter()
        writer.append(header.encoded())
        for parameter in parameters {
            writer.appendU32(parameter)
        }
        enqueue(writer.data)
    }

    // MARK: - MTPTransport

    func bulkOut(_ data: Data, timeout _: TimeInterval) throws {
        written.append(data)
    }

    func bulkIn(maxLength _: Int, timeout _: TimeInterval) throws -> Data {
        guard !inbound.isEmpty else {
            throw MTPError.transferFailed(underlying: NSError(
                domain: "MockTransport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no more scripted transfers"]
            ))
        }
        return inbound.removeFirst()
    }

    func deviceReset() throws {
        deviceResetCount += 1
        if let deviceResetError { throw deviceResetError }
    }

    func hardReset() {
        hardResetCount += 1
    }
}
