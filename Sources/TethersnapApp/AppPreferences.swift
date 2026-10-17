import Foundation
import TethersnapKit

/// The app's UserDefaults keys and their loaders. Nothing here touches the
/// filesystem: whether a stored path still exists is probed by the model off
/// the main actor (a path on an unmounted autofs or SMB share blocks for the
/// mount timeout, which must never hold up the first frame).
enum AppPreferences {
    private static let lastExportFolderKey = "lastExportFolderPath"
    private static let viewModeKey = "viewMode"
    private static let openedFoldersKey = "openedFolderPaths"

    private static var defaults: UserDefaults { .standard }

    // MARK: - Remembered export folder

    /// The last export destination as stored, unvalidated.
    static var rememberedExportFolder: URL? {
        defaults.string(forKey: lastExportFolderKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func saveRememberedExportFolder(_ url: URL?) {
        if let url {
            defaults.set(url.path, forKey: lastExportFolderKey)
        } else {
            defaults.removeObject(forKey: lastExportFolderKey)
        }
    }

    // MARK: - View mode

    static var viewMode: AppModel.ViewMode {
        let raw = defaults.string(forKey: viewModeKey)
        // "byGame" was the pre-source name of the folder grouping; both
        // shipped tags persisted it. Remove two releases after 0.3.0 ships.
        return raw == "byGame" ? .byFolder : raw.flatMap(AppModel.ViewMode.init(rawValue:)) ?? .all
    }

    static func saveViewMode(_ mode: AppModel.ViewMode) {
        defaults.set(mode.rawValue, forKey: viewModeKey)
    }

    // MARK: - Opened folders

    /// Every folder the user opened, in order, deduplicated by id. A folder on
    /// a drive that is not mounted right now stays in the list; the model
    /// hides it until it exists again instead of forgetting it.
    static var openedFolders: [CaptureSourceDescriptor] {
        var seen = Set<CaptureSourceDescriptor.ID>()
        return (defaults.stringArray(forKey: openedFoldersKey) ?? [])
            .map { CaptureSourceDescriptor.folder(URL(filePath: $0, directoryHint: .isDirectory)) }
            .filter { seen.insert($0.id).inserted }
    }

    static func saveOpenedFolders(_ folders: [CaptureSourceDescriptor]) {
        let paths = folders.compactMap { descriptor -> String? in
            if case let .folder(url) = descriptor.location { url.path } else { nil }
        }
        defaults.set(paths, forKey: openedFoldersKey)
    }
}

extension CaptureSourceDescriptor {
    /// The directory behind an opened folder; nil for devices and volumes.
    var folderURL: URL? {
        if case let .folder(url) = location { url } else { nil }
    }
}
