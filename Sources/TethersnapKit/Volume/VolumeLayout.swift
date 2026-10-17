import Foundation

/// How a mounted volume (or opened folder) organizes its captures. Known
/// console and camera layouts are scanned at their media roots only, so a
/// large card full of system folders is not walked end to end; everything
/// else gets a bounded generic walk.
public enum VolumeLayout: String, Sendable, CaseIterable {
    /// A drive the PS5 wrote: `PS5/CREATE/Screenshots/<Game>/…` and `PS5/CREATE/Video Clips/<Game>/…`.
    case ps5
    /// A drive the PS4 wrote: `PS4/SHARE/Screenshots/<Game>/…` and `PS4/SHARE/Video Clips/<Game>/…`.
    case ps4
    /// A Switch SD card: `Nintendo/Album/YYYY/MM/DD/…`.
    case switchAlbum
    /// A camera card: `DCIM/<1xxABCDE>/…`.
    case dcim
    /// Anything else (a Steam Deck export, a hand-made folder), walked from
    /// the root with a depth cap.
    case generic

    /// Detection order is the precedence: a card carrying both a Switch album
    /// and a `DCIM` folder is a Switch card.
    public static func detect(root: URL, fileManager: FileManager = .default) -> Self {
        for layout in allCases
            where layout != .generic && FileSystem.isDirectory(root.appendingPathComponent(layout.markerPath), fileManager: fileManager) {
            return layout
        }
        return .generic
    }

    /// Directories enumerated for captures; absent ones are skipped. The
    /// generic layout walks the root itself.
    public func mediaRoots(under root: URL, fileManager: FileManager = .default) -> [URL] {
        let relative: [String] = switch self {
        case .ps5: ["PS5/CREATE/Screenshots", "PS5/CREATE/Video Clips"]
        case .ps4: ["PS4/SHARE/Screenshots", "PS4/SHARE/Video Clips"]
        case .switchAlbum: ["Nintendo/Album"]
        case .dcim: ["DCIM"]
        case .generic: []
        }
        guard !relative.isEmpty else { return [root] }
        return relative.map { root.appendingPathComponent($0) }.filter { FileSystem.isDirectory($0, fileManager: fileManager) }
    }

    /// The grouping name for a capture under `mediaRoot`: the game folder
    /// (PS5/PS4), the date folder as `YYYY-MM-DD` (Switch album), the
    /// `100CANON` folder (DCIM), or the immediate parent (generic; nil for a
    /// file directly at the root).
    public func folderName(for file: URL, mediaRoot: URL) -> String? {
        folderName(for: file, mediaRootComponents: Self.resolvedComponents(of: mediaRoot))
    }

    /// Symlink-resolved path components of a media root, computed once per
    /// enumeration and handed to `folderName(for:mediaRootComponents:)`.
    public static func resolvedComponents(of url: URL) -> [String] {
        url.resolvingSymlinksInPath().pathComponents
    }

    /// `folderName(for:mediaRoot:)` with the media root already resolved.
    public func folderName(for file: URL, mediaRootComponents: [String]) -> String? {
        let components = Self.relativeDirectoryComponents(of: file, underResolved: mediaRootComponents)
        switch self {
        case .ps5, .ps4:
            return components.first
        case .switchAlbum:
            guard components.count >= 3 else { return components.last }
            return "\(components[0])-\(components[1])-\(components[2])"
        case .dcim, .generic:
            return components.last
        }
    }

    /// Directory depth below the media root that the walk does not enter;
    /// nil for the known layouts, whose media roots are shallow by design.
    public var maxDepth: Int? {
        switch self {
        case .ps5, .ps4, .switchAlbum, .dcim: nil
        case .generic: 6
        }
    }

    /// Filesystem housekeeping folders that are never walked.
    public static let skippedDirectoryNames: Set<String> = [
        "System Volume Information", "$RECYCLE.BIN", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
    ]

    private var markerPath: String {
        switch self {
        case .ps5: "PS5/CREATE"
        case .ps4: "PS4/SHARE"
        case .switchAlbum: "Nintendo/Album"
        case .dcim: "DCIM"
        case .generic: ""
        }
    }

    /// Path components of `file`'s directory below the resolved media root.
    /// The enumerator yields URLs under the media root as it was given, so
    /// the raw components usually match; symlinks (`/tmp` vs `/private/tmp`)
    /// are resolved only when they do not.
    private static func relativeDirectoryComponents(of file: URL, underResolved base: [String]) -> [String] {
        let directory = file.deletingLastPathComponent()
        let raw = directory.pathComponents
        if raw.count >= base.count, raw.prefix(base.count).elementsEqual(base) {
            return Array(raw.dropFirst(base.count))
        }
        let resolved = directory.resolvingSymlinksInPath().pathComponents
        guard resolved.count >= base.count, resolved.prefix(base.count).elementsEqual(base) else { return [] }
        return Array(resolved.dropFirst(base.count))
    }
}
