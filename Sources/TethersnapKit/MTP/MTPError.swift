import Foundation

/// Errors surfaced by the MTP/PTP stack.
public enum MTPError: Error {
    /// No USB device matching the vendor/product ID is attached (or it is not in MTP mode).
    case deviceNotFound
    /// The device was found but claiming it (or its MTP interface) failed.
    case claimFailed(String, underlying: Error?)
    /// No interface with a bulk-in/bulk-out pipe pair was found in the active configuration.
    case noMTPInterface
    /// A USB transfer failed (cable pulled, console left the transfer screen, timeout).
    case transferFailed(underlying: Error)
    /// Bytes received from the device do not form a valid PTP container/dataset.
    case malformedData(String)
    /// The device answered a transaction with a non-OK response code.
    case deviceResponse(PTPResponseCode)
    /// A response arrived for a different transaction than the one in flight.
    case transactionMismatch(expected: UInt32, received: UInt32)
    /// An earlier failure left the responder desynchronized; the connection must be rebuilt.
    case sessionInvalidated
    /// A leftover session from another host process could not be cleared
    /// in-band, so the console was USB-reset (software replug) and is
    /// re-enumerating; reconnect once it re-attaches.
    case staleSessionReset
}

extension MTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            Self.localized("error.device_not_found")
        case let .claimFailed(stage, underlying):
            String(format: Self.localized("error.claim_failed"), stage)
                + (underlying.map { " " + String(format: Self.localized("error.underlying"), $0.localizedDescription) } ?? "")
        case .noMTPInterface:
            Self.localized("error.no_mtp_interface")
        case let .transferFailed(underlying):
            String(format: Self.localized("error.transfer_failed"), underlying.localizedDescription)
        case let .malformedData(detail):
            String(format: Self.localized("error.malformed_data"), detail)
        case let .deviceResponse(code):
            String(format: Self.localized("error.device_response"), String(describing: code))
        case let .transactionMismatch(expected, received):
            String(format: Self.localized("error.transaction_mismatch"), Int(expected), Int(received))
        case .sessionInvalidated:
            Self.localized("error.session_invalidated")
        case .staleSessionReset:
            Self.localized("error.stale_session_reset")
        }
    }

    /// Table lookup in the package resource bundle (classic .lproj/.strings:
    /// `swift build` copies string catalogs raw without compiling them, so
    /// .xcstrings must never be used here).
    private static func localized(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
