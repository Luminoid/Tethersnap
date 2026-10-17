import Foundation

/// Tethersnap's log categories. The lowercase names are what `log show`/`log stream`
/// predicates match (`category == "usb"`).
package extension TethersnapLog.Category {
    /// IOUSBHost discovery, interface claims, bulk transfers, stall recovery.
    static let usb = TethersnapLog.Category("usb")
    /// PTP sessions and transactions.
    static let mtp = TethersnapLog.Category("mtp")
    /// Capture enumeration and downloads.
    static let library = TethersnapLog.Category("library")
    /// Mounted volumes and opened folders: mounts, walks, local thumbnails.
    static let volume = TethersnapLog.Category("volume")
    /// The app's state machine and exports.
    static let app = TethersnapLog.Category("app")
    /// Fixing capture dates from filenames.
    static let dates = TethersnapLog.Category("dates")
}
