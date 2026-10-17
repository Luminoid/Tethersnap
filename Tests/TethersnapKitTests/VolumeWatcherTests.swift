import Foundation
import Testing
@testable import TethersnapKit

@Suite("Volume watcher")
struct VolumeWatcherTests {
    @Test
    func `Only external local browsable volumes qualify`() {
        func candidate(browsable: Bool = true, removable: Bool = false, ejectable: Bool = false,
                       internal isInternal: Bool? = nil, root: Bool = false, local: Bool = true) -> Bool {
            VolumeWatcher.isCandidate(isBrowsable: browsable, isRemovable: removable, isEjectable: ejectable,
                                      isInternal: isInternal, isRootFileSystem: root, isLocal: local)
        }

        #expect(candidate(removable: true))
        #expect(candidate(ejectable: true))
        #expect(candidate(internal: false))
        #expect(!candidate()) // internal fixed disk, no external signal
        #expect(!candidate(removable: true, root: true))
        #expect(!candidate(removable: true, local: false))
        #expect(!candidate(browsable: false, removable: true))
    }

    @Test
    func `A volume descriptor prefers the filesystem UUID for its id`() {
        let url = URL(filePath: "/Volumes/SD", directoryHint: .isDirectory)

        #expect(CaptureSourceDescriptor.volume(url, name: "SD", uuid: "ABCD").id == "volume:ABCD")
        #expect(CaptureSourceDescriptor.volume(url, name: "SD", uuid: nil).id == "volume:/Volumes/SD")
        #expect(CaptureSourceDescriptor.volume(url, name: "SD", uuid: nil).kind == .volume)
    }

    @Test
    func `Only mount points under Volumes count as user volumes`() {
        #expect(VolumeWatcher.isUserMountPoint(URL(filePath: "/Volumes/SD", directoryHint: .isDirectory)))
        #expect(VolumeWatcher.isUserMountPoint(URL(filePath: "/Volumes/PS5 Drive")))
        #expect(!VolumeWatcher.isUserMountPoint(URL(filePath: "/System/Volumes/Update/mnt1")))
        #expect(!VolumeWatcher.isUserMountPoint(URL(filePath: "/System/Volumes/Data")))
        #expect(!VolumeWatcher.isUserMountPoint(URL(filePath: "/")))
        #expect(!VolumeWatcher.isUserMountPoint(URL(filePath: "/Volumes")))
    }
}
