import Foundation

/// Reads PTP containers off the bulk-in pipe, tolerating headers split across
/// transfers, several containers coalesced into one transfer, and stray
/// zero-length packets. Internal so framing edge cases are unit-testable
/// without scripting a whole session.
struct PTPContainerReader {
    let transport: MTPTransport
    let chunkSize: Int
    let timeout: TimeInterval
    private var leftover = Data()

    /// Streamed data phases (GetObject) may be gigabytes; anything we have to
    /// hold in memory may not.
    static let maxBufferedPayload = 64 * 1024 * 1024
    /// PIMA 15740 container length meaning "unknown, or 4 GiB and more": the
    /// data phase then ends with a short packet (or a zero-length one) instead.
    static let unknownLength: UInt32 = 0xFFFF_FFFF
    /// Consecutive zero-length reads tolerated before the phase counts as dead.
    private static let maxEmptyReads = 2
    init(transport: MTPTransport, chunkSize: Int, timeout: TimeInterval) {
        self.transport = transport
        self.chunkSize = chunkSize
        self.timeout = timeout
    }

    /// Read one full container. Data-container payloads stream to `dataSink`;
    /// response payloads are returned whole. A data phase nobody asked for is
    /// consumed and dropped (empty `Data` returned).
    mutating func next(dataSink: ((Data) throws -> Void)?, responseTimeout: TimeInterval) throws -> (PTPContainerHeader, Data) {
        try fill(until: PTPContainerHeader.encodedSize, timeout: responseTimeout)
        let header = try PTPContainerHeader.decode(leftover)
        leftover.removeFirst(PTPContainerHeader.encodedSize)
        let payloadLength = header.payloadLength

        if header.type == .data, let dataSink {
            if header.length == Self.unknownLength {
                try streamUnknownLength(into: dataSink)
                return (header, Data())
            }
            var remaining = payloadLength
            if !leftover.isEmpty {
                let take = min(leftover.count, remaining)
                try dataSink(leftover.prefix(take))
                leftover.removeFirst(take)
                remaining -= take
            }
            var emptyReads = 0
            while remaining > 0 {
                let chunk = try readTransfer(maxLength: min(chunkSize, roundUpToPacket(remaining)), timeout: timeout)
                if chunk.isEmpty {
                    // Same tolerance as `fill`: a responder stuck emitting
                    // zero-length packets must not spin the caller forever.
                    emptyReads += 1
                    guard emptyReads <= Self.maxEmptyReads else {
                        throw MTPError.malformedData("device stopped sending while \(remaining) data bytes were still expected")
                    }
                    continue
                }
                emptyReads = 0
                let take = min(chunk.count, remaining)
                try dataSink(chunk.prefix(take))
                if take < chunk.count {
                    leftover.append(chunk.suffix(from: chunk.startIndex + take))
                }
                remaining -= take
            }
            return (header, Data())
        }

        // Buffered path (responses, or a data phase nobody asked for): a bogus
        // length here would otherwise become a giant allocation.
        guard payloadLength <= Self.maxBufferedPayload else {
            throw MTPError.malformedData("implausible \(header.type) container length \(header.length)")
        }
        try fill(until: payloadLength, timeout: responseTimeout)
        let payload = header.type == .response ? Data(leftover.prefix(payloadLength)) : Data()
        leftover.removeFirst(payloadLength)
        return (header, payload)
    }

    /// Data phase of unknown length (4 GiB clips on a camera): the responder
    /// ends it with a transfer shorter than requested, a zero-length packet
    /// when the length was a packet multiple. Whatever the header read
    /// already pulled in belongs to the data; the response container can only
    /// start in a later transfer because the short packet ends this one.
    private mutating func streamUnknownLength(into dataSink: (Data) throws -> Void) throws {
        if !leftover.isEmpty {
            try dataSink(leftover)
            leftover.removeAll(keepingCapacity: true)
        }
        var total = 0
        while true {
            let chunk = try readTransfer(maxLength: chunkSize, timeout: timeout)
            if !chunk.isEmpty {
                try dataSink(chunk)
                total += chunk.count
            }
            if chunk.count < chunkSize {
                TethersnapLog.debug(.mtp, "unknown-length data phase ended after \(total) bytes")
                return
            }
        }
    }

    /// Ensure `leftover` holds at least `count` bytes.
    private mutating func fill(until count: Int, timeout: TimeInterval) throws {
        var emptyReads = 0
        while leftover.count < count {
            let chunk = try readTransfer(maxLength: chunkSize, timeout: timeout)
            if chunk.isEmpty {
                emptyReads += 1
                TethersnapLog.debug(.mtp, "zero-length bulk-in read \(emptyReads) with \(count - leftover.count) bytes still expected")
                guard emptyReads <= Self.maxEmptyReads else {
                    throw MTPError.malformedData("device stopped sending while \(count - leftover.count) bytes were still expected")
                }
                continue // zero-length packet; try again
            }
            emptyReads = 0
            leftover.append(chunk)
        }
    }

    private func readTransfer(maxLength: Int, timeout: TimeInterval) throws -> Data {
        try transport.bulkIn(maxLength: maxLength, timeout: timeout)
    }

    /// Bulk-in requests must be whole multiples of the packet size; 1024 covers
    /// every bus speed (64/512/1024 all divide it).
    private func roundUpToPacket(_ length: Int) -> Int {
        let packet = 1024
        return ((length + packet - 1) / packet) * packet
    }
}
