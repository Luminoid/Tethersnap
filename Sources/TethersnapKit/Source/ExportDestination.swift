import Foundation

/// Where one item lands in an export: the directory it is written into, under
/// its `exportFilename`.
public struct ExportDestination: Sendable, Equatable {
    public let item: CaptureItem
    public let directory: URL

    public init(item: CaptureItem, directory: URL) {
        self.item = item
        self.directory = directory
    }
}

public extension [CaptureItem] {
    /// Destinations under `root`. Flat: everything straight into `root` under
    /// the globally unique `exportFilename`. Grouped: one subfolder per source
    /// folder (`exportFolderName`; items without one stay in `root`), with
    /// names made unique within each subfolder instead, so `100CANON/IMG_0001.JPG`
    /// and `101CANON/IMG_0001.JPG` both keep their own name.
    func exportDestinations(under root: URL, groupedByFolder: Bool) -> [ExportDestination] {
        guard groupedByFolder else {
            return map { ExportDestination(item: $0, directory: root) }
        }
        var resolved = self
        let indicesByFolder = Dictionary(grouping: indices) { self[$0].exportFolderName }
        for indices in indicesByFolder.values {
            let group = indices.map { index in
                var item = self[index]
                item.exportFilename = item.filename
                return item
            }.resolvingFilenameCollisions()
            for (offset, index) in indices.enumerated() {
                resolved[index] = group[offset]
            }
        }
        return resolved.map { item in
            let directory = item.exportFolderName.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
            return ExportDestination(item: item, directory: directory)
        }
    }
}
