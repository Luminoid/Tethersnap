import Foundation

/// Abstracts the bulk pipes an MTP responder is driven through, so the
/// protocol layer can be exercised against a mock without hardware.
///
/// Implementations are synchronous and single-threaded by design; drive a
/// session from one thread (or wrap it in an actor at the call site).
public protocol MTPTransport: AnyObject {
    /// Write one buffer to the bulk-out pipe.
    func bulkOut(_ data: Data, timeout: TimeInterval) throws
    /// Read one USB transfer from the bulk-in pipe. Returns up to `maxLength`
    /// bytes; the transfer ends early on a short packet, so the result may be
    /// smaller (including empty for a zero-length packet).
    func bulkIn(maxLength: Int, timeout: TimeInterval) throws -> Data
    /// Class-specific Device Reset (PIMA 15740 USB class, bRequest 0x66):
    /// returns the responder to Idle and cancels any open session. Recovery
    /// for a stale session left behind by another host process.
    func deviceReset() throws
    /// USB-level device reset (software replug): re-enumerates the device,
    /// which clears responder state the class request cannot (the Switch 2
    /// STALLs Device Reset). Best effort; the transport is unusable afterwards
    /// and the caller must build a new connection once the device re-attaches.
    func hardReset()
}
