import Foundation
import Testing
@testable import TethersnapKit

@Suite("Export destinations")
struct ExportDestinationTests {
    private static let root = URL(fileURLWithPath: "/tmp/tethersnap-export", isDirectory: true)

    private func item(_ filename: String, handle: UInt32, storage: UInt32 = 1, folder: String?) -> CaptureItem {
        CaptureItem(handle: handle, storageID: storage, filename: filename, kind: .image, sizeInBytes: 1, date: nil, folderName: folder)
    }

    @Test
    func `A flat export keeps the global names and the root`() {
        let items = [item("IMG_0001.JPG", handle: 1, folder: "100CANON"), item("IMG_0001.JPG", handle: 2, folder: "101CANON")]
            .resolvingFilenameCollisions()

        let destinations = items.exportDestinations(under: Self.root, groupedByFolder: false)

        #expect(destinations.map(\.directory.path) == [Self.root.path, Self.root.path])
        #expect(destinations.map(\.item.exportFilename) == ["IMG_0001.JPG", "IMG_0001-2.JPG"])
    }

    @Test
    func `A grouped export puts each folder's items in a subfolder under their own names`() {
        let items = [
            item("IMG_0001.JPG", handle: 1, folder: "100CANON"),
            item("IMG_0001.JPG", handle: 2, folder: "101CANON"),
            item("loose.jpg", handle: 3, folder: nil),
        ].resolvingFilenameCollisions()

        let destinations = items.exportDestinations(under: Self.root, groupedByFolder: true)

        #expect(destinations.map(\.directory.lastPathComponent) == ["100CANON", "101CANON", "tethersnap-export"])
        #expect(destinations.map { $0.directory.deletingLastPathComponent().path } == [Self.root.path, Self.root.path, "/tmp"])
        #expect(destinations.map(\.item.exportFilename) == ["IMG_0001.JPG", "IMG_0001.JPG", "loose.jpg"])
        #expect(destinations.map(\.item.id) == items.map(\.id))
    }

    @Test
    func `Duplicates inside one folder are still numbered`() {
        let items = [item("shot.jpg", handle: 1, storage: 1, folder: "Game"), item("shot.jpg", handle: 2, storage: 2, folder: "Game")]
            .resolvingFilenameCollisions()

        let destinations = items.exportDestinations(under: Self.root, groupedByFolder: true)

        #expect(destinations.map(\.item.exportFilename) == ["shot.jpg", "shot-2.jpg"])
        #expect(Set(destinations.map(\.directory.path)).count == 1)
    }

    @Test
    func `Folder names become directory names the Finder can show`() {
        #expect(CaptureItem.exportFolderComponent("Animal Crossing: New Horizons") == "Animal Crossing - New Horizons")
        #expect(CaptureItem.exportFolderComponent("Zelda:TOTK") == "Zelda-TOTK")
        #expect(CaptureItem.exportFolderComponent("A/B  C") == "A-B C")
        #expect(CaptureItem.exportFolderComponent("..hidden") == "hidden")
        #expect(CaptureItem.exportFolderComponent("...") == nil)
        #expect(CaptureItem.exportFolderComponent("  ") == nil)

        let unusable = item("x.jpg", handle: 1, folder: ".")
        #expect(unusable.exportFolderName == nil)
        let destinations = [unusable].exportDestinations(under: Self.root, groupedByFolder: true)
        #expect(destinations.map(\.directory.path) == [Self.root.path])
    }
}
