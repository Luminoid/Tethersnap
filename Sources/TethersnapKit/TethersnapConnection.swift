import Foundation

/// Convenience facade: claim the console over USB, open a PTP session, and
/// expose the capture library. Shared by the CLI and the app.
public final class TethersnapConnection {
    public let deviceID: USBMTPTransport.DeviceID
    public let session: MTPSession
    public let library: CaptureLibrary
    /// DeviceInfo fetched once at connect (model, firmware, supported operations).
    public let cachedDeviceInfo: PTPDeviceInfo

    private let transport: MTPTransport

    /// Internal seam so the connect handshake is testable against a mock.
    init(transport: MTPTransport, deviceID: USBMTPTransport.DeviceID) throws {
        self.transport = transport
        self.deviceID = deviceID
        session = MTPSession(transport: transport)
        library = CaptureLibrary(session: session)
        cachedDeviceInfo = try Self.handshake(session: session)
        TethersnapLog.info(TethersnapLog.mtp, "connected to \(cachedDeviceInfo.model.isEmpty ? deviceID.name : cachedDeviceInfo.model) v\(cachedDeviceInfo.deviceVersion)")
    }

    /// Preferred handshake is the spec's: sessionless GetDeviceInfo on
    /// transaction 0, then OpenSession. The real Switch 2 accepts that on a
    /// fresh entry into transfer mode, but on RE-entry it has answered
    /// transaction 0 with an empty data phase + InvalidTransactionID
    /// (observed 2026-08-30, firmware 22.5.0). Fallback: pause briefly, open
    /// the session first and fetch DeviceInfo inside it with a normal
    /// transaction ID. A stale session left by another host process (also
    /// observed same day: SessionAlreadyOpen + InvalidTransactionID on every
    /// request) is recovered inside `MTPSession.open()`.
    private static func handshake(session: MTPSession) throws -> PTPDeviceInfo {
        do {
            let info = try session.deviceInfo()
            try session.open()
            return info
        } catch let MTPError.deviceResponse(code) {
            TethersnapLog.info(TethersnapLog.mtp, "sessionless GetDeviceInfo rejected (\(code)); retrying with session-first handshake")
        }
        Thread.sleep(forTimeInterval: 0.3)
        try session.open()
        return try session.deviceInfo()
    }

    deinit {
        close()
    }

    /// Whether the responder implements GetThumb (used for grid thumbnails).
    public var supportsThumbnails: Bool {
        cachedDeviceInfo.supports(.getThumb)
    }

    /// Whether the responder implements GetPartialObject (bounded thumbnail prefixes).
    public var supportsPartialObject: Bool {
        cachedDeviceInfo.supports(.getPartialObject)
    }

    /// False once a failure desynchronized the session; the connection must be
    /// discarded and rebuilt.
    public var isSessionValid: Bool {
        session.isValid
    }

    /// Connect to the first attached supported console. When stale-session
    /// recovery had to USB-reset the console (software replug), wait for it to
    /// re-enumerate and try once more before giving up.
    public static func connect() throws -> TethersnapConnection {
        do {
            return try connectOnce()
        } catch MTPError.staleSessionReset {
            TethersnapLog.info(TethersnapLog.mtp, "waiting for the console to re-enumerate after the USB reset")
            Thread.sleep(forTimeInterval: 3)
            return try connectOnce()
        }
    }

    private static func connectOnce() throws -> TethersnapConnection {
        let transport = try USBMTPTransport()
        return try TethersnapConnection(transport: transport, deviceID: transport.deviceID)
    }

    /// Descriptor summary of the claimed interface, for diagnostics.
    public var interfaceSummary: USBMTPTransport.InterfaceSummary? {
        (transport as? USBMTPTransport)?.interfaceSummary
    }

    /// Close the session and release the USB device. Idempotent; also runs on
    /// deinit so a dropped connection still sends CloseSession.
    public func close() {
        session.close()
        (transport as? USBMTPTransport)?.shutdown()
    }
}
