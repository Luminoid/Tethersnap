import Foundation

/// A PTP session over an `MTPTransport`: transaction sequencing plus typed
/// wrappers for the baseline operations Tethersnap needs.
///
/// Deliberately baseline-only. The Switch 2 reports no MTP vendor extension
/// (extension ID 0xFFFFFFFF), which is what breaks Android-oriented clients
/// that lean on GetObjectPropList; everything here is plain PIMA 15740.
public final class MTPSession {
    /// Result of one transaction: the response code and its parameters.
    public struct TransactionResult {
        public let response: PTPResponseCode
        public let parameters: [UInt32]
    }

    private let transport: MTPTransport
    private var nextTransactionID: UInt32 = 1
    private var isOpen = false
    /// False once a failure left the responder mid-conversation (abandoned data
    /// phase, transport error, malformed stream). A desynchronized session must
    /// be thrown away and reconnected, never resumed; every transaction on an
    /// invalidated session throws `MTPError.sessionInvalidated`.
    public private(set) var isValid = true

    /// One bulk-in request size. A multiple of every legal wMaxPacketSize.
    private let readChunkSize = 512 * 1024
    private let commandTimeout: TimeInterval = 5
    private let responseTimeout: TimeInterval = 30
    private let dataTimeout: TimeInterval = 30

    public init(transport: MTPTransport) {
        self.transport = transport
    }

    // MARK: - Session lifecycle

    /// Open session 1. A responder that considers a session open already is
    /// carrying stale state from an unclean host exit; recover instead of
    /// continuing (see `recoverStaleSession`).
    public func open() throws {
        do {
            _ = try transaction(.openSession, parameters: [1])
        } catch let MTPError.deviceResponse(code) where code == .sessionAlreadyOpen {
            try recoverStaleSession()
        }
        isOpen = true
        TethersnapLog.info(TethersnapLog.mtp, "session open")
    }

    /// A stale session survives whatever host process left it behind (a killed
    /// CLI run, another PTP client), and its transaction counter is unknown,
    /// so every request we would make inside it comes back
    /// InvalidTransactionID (observed on fw 22.5.0: even in-session
    /// GetDeviceInfo with tx 1 is rejected). Continuing is hopeless. Close the
    /// stale session; when the responder rejects even that (the close itself
    /// needs a valid transaction ID), fall back to the class-specific Device
    /// Reset, then reopen.
    private func recoverStaleSession() throws {
        TethersnapLog.info(TethersnapLog.mtp, "responder reports a stale session (another MTP app?); closing it and reopening")
        do {
            _ = try transaction(.closeSession)
        } catch let MTPError.deviceResponse(code) {
            TethersnapLog.info(TethersnapLog.mtp, "stale-session CloseSession rejected (\(code)); sending class Device Reset")
            do {
                try transport.deviceReset()
                Thread.sleep(forTimeInterval: 0.5)
            } catch {
                // The console STALLs the class request (observed fw 22.5.0);
                // the remaining cure is a USB re-enumeration, after which this
                // transport is gone and the caller reconnects fresh.
                TethersnapLog.info(TethersnapLog.mtp, "class Device Reset unavailable; issuing a USB re-enumeration")
                isValid = false
                transport.hardReset()
                throw MTPError.staleSessionReset
            }
        }
        _ = try transaction(.openSession, parameters: [1])
    }

    public func close() {
        guard isOpen else { return }
        defer { isOpen = false }
        guard isValid else {
            TethersnapLog.info(TethersnapLog.mtp, "session invalidated earlier; skipping CloseSession")
            return
        }
        do {
            _ = try transaction(.closeSession)
            TethersnapLog.info(TethersnapLog.mtp, "session closed")
        } catch {
            TethersnapLog.info(TethersnapLog.mtp, "CloseSession failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Operations

    /// GetDeviceInfo works outside a session and always uses transaction ID 0.
    public func deviceInfo() throws -> PTPDeviceInfo {
        var payload = Data()
        _ = try transaction(.getDeviceInfo, dataSink: { payload.append($0) })
        return try PTPDeviceInfo.decode(payload)
    }

    public func storageIDs() throws -> [UInt32] {
        var payload = Data()
        _ = try transaction(.getStorageIDs, dataSink: { payload.append($0) })
        var reader = PTPDataReader(payload)
        return try reader.readU32Array()
    }

    public func storageInfo(for storageID: UInt32) throws -> PTPStorageInfo {
        var payload = Data()
        _ = try transaction(.getStorageInfo, parameters: [storageID], dataSink: { payload.append($0) })
        return try PTPStorageInfo.decode(payload)
    }

    /// GetObjectHandles. `parent` nil means "all objects in the store";
    /// `PTPWildcard.rootParent` means the root level only.
    public func objectHandles(storageID: UInt32 = PTPWildcard.allStorages,
                              format: UInt32 = PTPWildcard.any,
                              parent: UInt32? = nil) throws -> [UInt32] {
        var payload = Data()
        _ = try transaction(
            .getObjectHandles,
            parameters: [storageID, format, parent ?? PTPWildcard.any],
            dataSink: { payload.append($0) }
        )
        var reader = PTPDataReader(payload)
        return try reader.readU32Array()
    }

    public func objectInfo(for handle: UInt32) throws -> PTPObjectInfo {
        var payload = Data()
        _ = try transaction(.getObjectInfo, parameters: [handle], dataSink: { payload.append($0) })
        return try PTPObjectInfo.decode(payload)
    }

    /// GetObject, streaming the payload to `sink` chunk by chunk.
    public func object(for handle: UInt32,
                       sink: (Data) throws -> Void,
                       progress: ((Int64) -> Void)? = nil) throws {
        try stream(.getObject, handle: handle, sink: sink, progress: progress)
    }

    /// GetThumb: the device-generated thumbnail, when the responder offers one.
    public func thumb(for handle: UInt32, sink: (Data) throws -> Void) throws {
        try stream(.getThumb, handle: handle, sink: sink, progress: nil)
    }

    /// GetPartialObject: up to `maxBytes` of the object starting at `offset`.
    /// In the Switch 2's supported set; used to fetch image prefixes for
    /// thumbnailing when the responder offers no GetThumb.
    public func partialObject(for handle: UInt32, offset: UInt32 = 0, maxBytes: UInt32) throws -> Data {
        var payload = Data()
        _ = try transaction(.getPartialObject, parameters: [handle, offset, maxBytes], dataSink: { payload.append($0) })
        return payload
    }

    private func stream(_ operation: PTPOperationCode,
                        handle: UInt32,
                        sink: (Data) throws -> Void,
                        progress: ((Int64) -> Void)?) throws {
        var received: Int64 = 0
        try withoutActuallyEscaping(sink) { sink in
            _ = try transaction(operation, parameters: [handle], dataSink: { chunk in
                received += Int64(chunk.count)
                try sink(chunk)
                progress?(received)
            })
        }
    }

    // MARK: - Transaction engine

    /// Run one command → (data-in) → response transaction.
    @discardableResult
    public func transaction(_ operation: PTPOperationCode,
                            parameters: [UInt32] = [],
                            dataSink: ((Data) throws -> Void)? = nil) throws -> TransactionResult {
        guard isValid else { throw MTPError.sessionInvalidated }
        do {
            return try performTransaction(operation, parameters: parameters, dataSink: dataSink)
        } catch {
            // A non-OK response code is a clean transaction end; everything else
            // (transport failure, malformed stream, an abandoned data phase)
            // leaves the responder desynchronized.
            if case MTPError.deviceResponse = error {} else {
                isValid = false
                TethersnapLog.error(TethersnapLog.mtp, "session invalidated by \(operation): \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func performTransaction(_ operation: PTPOperationCode,
                                    parameters: [UInt32],
                                    dataSink: ((Data) throws -> Void)?) throws -> TransactionResult {
        let transactionID = claimTransactionID(for: operation)
        let command = try PTPContainer.command(operation, transactionID: transactionID, parameters: parameters)
        let parameterHex = parameters.map { String(format: "0x%08X", $0) }.joined(separator: " ")
        TethersnapLog.debug(TethersnapLog.mtp, "→ \(operation) tx \(transactionID) [\(parameterHex)]")
        try transport.bulkOut(command, timeout: commandTimeout)

        var dataBytes = 0
        let countingSink: ((Data) throws -> Void)? = dataSink.map { sink in
            { chunk in
                dataBytes += chunk.count
                try sink(chunk)
            }
        }

        var reader = PTPContainerReader(transport: transport, chunkSize: readChunkSize, timeout: dataTimeout)
        var strayEvents = 0
        while true {
            let (header, payload) = try reader.next(dataSink: countingSink, responseTimeout: responseTimeout)
            switch header.type {
            case .data:
                guard header.transactionID == transactionID else {
                    throw MTPError.transactionMismatch(expected: transactionID, received: header.transactionID)
                }
                // Payload already streamed to dataSink; loop for the response.
                continue
            case .response:
                guard header.transactionID == transactionID else {
                    throw MTPError.transactionMismatch(expected: transactionID, received: header.transactionID)
                }
                let code = PTPResponseCode(rawValue: header.code)
                TethersnapLog.debug(TethersnapLog.mtp, "← \(code) tx \(transactionID), \(dataBytes) data bytes")
                guard code.isOK else {
                    throw MTPError.deviceResponse(code)
                }
                let responseParameters = try PTPContainer.responseParameters(header: header, payload: payload)
                return TransactionResult(response: code, parameters: responseParameters)
            case .event:
                strayEvents += 1
                guard strayEvents <= Self.maxStrayEventContainers else {
                    throw MTPError.malformedData("more than \(Self.maxStrayEventContainers) stray event containers in one transaction")
                }
                TethersnapLog.debug(TethersnapLog.mtp, "ignoring stray event container (code 0x\(String(format: "%04X", header.code)))")
                continue // events belong to the interrupt pipe; ignore strays
            case .command:
                throw MTPError.malformedData("unexpected command container from device")
            }
        }
    }

    /// A responder spamming event containers on the bulk pipe must not loop forever.
    private static let maxStrayEventContainers = 8

    private func claimTransactionID(for operation: PTPOperationCode) -> UInt32 {
        // The spec pins OpenSession (and sessionless GetDeviceInfo) to ID 0.
        switch operation {
        case .openSession:
            nextTransactionID = 1
            return 0
        case .getDeviceInfo where !isOpen:
            return 0
        default:
            defer { nextTransactionID &+= 1; if nextTransactionID == 0 { nextTransactionID = 1 } }
            return nextTransactionID
        }
    }
}
