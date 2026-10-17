import AppKit
import Foundation

/// Mount and unmount notifications for external volumes (USB drives, memory
/// cards), plus the current list. Lives on the main actor because
/// `NSWorkspace` posts there; `mountedVolumes()` needs no run loop and
/// serves the CLI too.
@MainActor
public final class VolumeWatcher {
    public enum Event: Sendable {
        case mounted(CaptureSourceDescriptor)
        case unmounted(URL)
    }

    private let handler: @Sendable (Event) -> Void

    public init(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
        // Selector observers unregister themselves on dealloc, so no deinit
        // has to touch non-Sendable observer tokens.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumeDidMount(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumeDidUnmount(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        TethersnapLog.info(.volume, "volume watcher armed")
    }

    /// Stop delivering events; safe to call more than once.
    public func invalidate() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func volumeDidMount(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        guard let descriptor = Self.descriptor(forVolumeAt: url) else {
            TethersnapLog.debug(.volume, "ignoring a mounted volume that is not external", private: url.path)
            return
        }
        TethersnapLog.notice(.volume, "volume mounted: \(descriptor.name)", private: url.path)
        handler(.mounted(descriptor))
    }

    @objc private func volumeDidUnmount(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        // Resource values are unreadable once unmounted, so the mount point
        // tells user volumes from system plumbing. The event still goes out:
        // opened folders are re-probed on every unmount.
        if Self.isUserMountPoint(url) {
            TethersnapLog.notice(.volume, "volume unmounted", private: url.path)
        } else {
            TethersnapLog.debug(.volume, "system volume unmounted", private: url.path)
        }
        handler(.unmounted(url))
    }

    // MARK: - Listing

    private nonisolated static let resourceKeys: Set<URLResourceKey> = [
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
        .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeLocalizedNameKey, .volumeUUIDStringKey,
    ]

    /// Every mounted external volume, by name.
    public nonisolated static func mountedVolumes() -> [CaptureSourceDescriptor] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(resourceKeys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { descriptor(forVolumeAt: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The descriptor for a mounted volume, nil when it is not one Tethersnap
    /// lists (the boot volume, network shares, non-browsable volumes).
    nonisolated static func descriptor(forVolumeAt url: URL) -> CaptureSourceDescriptor? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys),
              isCandidate(
                  isBrowsable: values.volumeIsBrowsable ?? false,
                  isRemovable: values.volumeIsRemovable ?? false,
                  isEjectable: values.volumeIsEjectable ?? false,
                  isInternal: values.volumeIsInternal,
                  isRootFileSystem: values.volumeIsRootFileSystem ?? false,
                  isLocal: values.volumeIsLocal ?? false
              ) else { return nil }
        return .volume(url, name: values.volumeLocalizedName ?? url.lastPathComponent, uuid: values.volumeUUIDString)
    }

    /// True under `/Volumes`, where macOS mounts every volume the Finder shows
    /// (drives, cards, disk images, network shares). System volumes mount
    /// elsewhere, such as the `/System/Volumes/Update/mnt1` staging volume a
    /// macOS update mounts and unmounts repeatedly.
    nonisolated static func isUserMountPoint(_ url: URL) -> Bool {
        url.path.hasPrefix("/Volumes/")
    }

    /// External means removable, ejectable, or reported as not internal; the
    /// boot volume and network shares never qualify.
    nonisolated static func isCandidate(isBrowsable: Bool, isRemovable: Bool, isEjectable: Bool,
                                        isInternal: Bool?, isRootFileSystem: Bool, isLocal: Bool) -> Bool {
        isBrowsable && isLocal && !isRootFileSystem && (isRemovable || isEjectable || isInternal == false)
    }
}
