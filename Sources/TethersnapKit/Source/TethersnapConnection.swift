import Foundation

/// Convenience facade: claim a PTP device over USB, open a session, and
/// expose the capture library. Shared by the CLI and the app; the
/// `CaptureSource` conformance (separate file) is how the app drives it.
public final class TethersnapConnection {
    public let deviceID: USBMTPTransport.DeviceID
    public let session: MTPSession
    public let library: CaptureLibrary
    /// DeviceInfo fetched once at connect (model, firmware, supported operations).
    public let cachedDeviceInfo: PTPDeviceInfo
    /// Same id as the pre-connect `deviceID.descriptor`; the name is the
    /// responder's model when it reports one, the detail its firmware.
    public let descriptor: CaptureSourceDescriptor

    private let transport: MTPTransport

    /// Internal seam so the connect handshake is testable against a mock.
    init(transport: MTPTransport, deviceID: USBMTPTransport.DeviceID) throws {
        self.transport = transport
        self.deviceID = deviceID
        session = MTPSession(transport: transport)
        library = CaptureLibrary(session: session)
        let info = try Self.handshake(session: session)
        cachedDeviceInfo = info
        let base = deviceID.descriptor
        descriptor = CaptureSourceDescriptor(
            id: base.id,
            name: info.model.isEmpty ? base.name : info.model,
            kind: base.kind,
            detail: info.deviceVersion.isEmpty ? base.detail : "v\(info.deviceVersion)",
            location: base.location
        )
        TethersnapLog.notice(.mtp, "connected to \(descriptor.name) v\(info.deviceVersion)")
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
            do {
                try session.open()
                return info
            } catch let MTPError.deviceResponse(code) {
                TethersnapLog.notice(.mtp, "OpenSession rejected (\(code)) after sessionless GetDeviceInfo; retrying with session-first handshake")
            }
        } catch let MTPError.deviceResponse(code) {
            TethersnapLog.notice(.mtp, "sessionless GetDeviceInfo rejected (\(code)); retrying with session-first handshake")
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

    /// Connect to one attached device. When stale-session recovery had to
    /// USB-reset it (software replug), wait for it to re-enumerate at the same
    /// location and try once more before giving up.
    public static func connect(to deviceID: USBMTPTransport.DeviceID) throws -> TethersnapConnection {
        do {
            return try connectOnce(deviceID)
        } catch MTPError.staleSessionReset {
            TethersnapLog.notice(.mtp, "waiting for \(deviceID.name) to re-enumerate after the USB reset")
            Thread.sleep(forTimeInterval: 3)
            return try connectOnce(deviceID)
        }
    }

    private static func connectOnce(_ deviceID: USBMTPTransport.DeviceID) throws -> TethersnapConnection {
        let transport = try USBMTPTransport(deviceID: deviceID)
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

    /// Release the USB device without a CloseSession round trip, for a device
    /// the system already reported removed (see `MTPSession.abandon()`).
    public func abandon() {
        session.abandon()
        (transport as? USBMTPTransport)?.shutdown()
    }
}
