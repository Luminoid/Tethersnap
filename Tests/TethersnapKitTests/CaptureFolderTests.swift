import Foundation
import Testing
@testable import TethersnapKit

@Suite("Capture folders")
struct CaptureFolderTests {
    private let now = Date()

    private func item(_ handle: UInt32, folder: String?, kind: CaptureItem.Kind = .image, minutesAgo: Double?) -> CaptureItem {
        CaptureItem(
            handle: handle, storageID: 0x0001_0001, filename: "\(handle).jpg", kind: kind, sizeInBytes: 1,
            date: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, folderName: folder
        )
    }

    @Test
    func `The folder with the newest capture comes first`() {
        let items = [
            item(1, folder: "Mario Kart World", minutesAgo: 10),
            item(2, folder: "Hyrule Warriors", minutesAgo: 5),
            item(3, folder: "Mario Kart World", minutesAgo: 1),
            item(4, folder: "Kirby Air Riders", minutesAgo: 60),
        ]

        let folders = items.folders()

        #expect(folders.map(\.name) == ["Mario Kart World", "Hyrule Warriors", "Kirby Air Riders"])
        #expect(folders.map(\.count) == [2, 1, 1])
    }

    @Test
    func `Counts follow the kind, the order and the list do not`() {
        let items = [
            item(1, folder: "A", kind: .image, minutesAgo: 1),
            item(2, folder: "B", kind: .video, minutesAgo: 5),
            item(3, folder: "B", kind: .image, minutesAgo: 6),
        ]

        let folders = items.folders(counting: .video)

        #expect(folders.map(\.name) == ["A", "B"])
        #expect(folders.map(\.count) == [0, 1])
    }

    @Test
    func `Undated folders follow dated ones by name, items without a folder come last`() {
        let items = [
            item(1, folder: nil, minutesAgo: 0),
            item(2, folder: "b", minutesAgo: nil),
            item(3, folder: "a", minutesAgo: nil),
            item(4, folder: "dated", minutesAgo: 30),
        ]

        #expect(items.folders().map(\.name) == ["dated", "a", "b", nil])
    }

    @Test
    func `inFolder keeps one folder, nil keeps the items without one`() {
        let items = [item(1, folder: "A", minutesAgo: 1), item(2, folder: nil, minutesAgo: 2), item(3, folder: "A", minutesAgo: 3)]

        #expect(items.inFolder("A").map(\.handle) == [1, 3])
        #expect(items.inFolder(nil).map(\.handle) == [2])
        #expect(items.inFolder("Missing").isEmpty)
    }
}
