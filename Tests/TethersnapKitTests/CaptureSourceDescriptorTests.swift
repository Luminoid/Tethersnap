import Foundation
import Testing
@testable import TethersnapKit

@Suite("Capture source descriptors")
struct CaptureSourceDescriptorTests {
    @Test
    func `USB ids carry the location so two identical devices stay distinct`() {
        let table = USBMTPTransport.DeviceID.switch2
        let left = USBMTPTransport.DeviceID(vendorID: 0x057E, productID: 0x2061, name: "Nintendo Switch 2", locationID: 0x1420_0000)
        let right = USBMTPTransport.DeviceID(vendorID: 0x057E, productID: 0x2061, name: "Nintendo Switch 2", locationID: 0x1430_0000)

        #expect(table.descriptor.id == "usb:00000000:057e:2061")
        #expect(left.descriptor.id == "usb:14200000:057e:2061")
        #expect(left.descriptor.id != right.descriptor.id)
        #expect(left.descriptor.kind == .console)
        #expect(left.descriptor.detail == "057e:2061")
        #expect(left.descriptor.location == .usb(left))
        #expect(left != right)
        #expect(USBMTPTransport.DeviceID.known(vendorID: 0x057E, productID: 0x201D)?.name == "Nintendo Switch")
        #expect(USBMTPTransport.DeviceID.known(vendorID: 0x04A9, productID: 0x32F9) == nil)
    }

    @Test
    func `Folder and volume descriptors are keyed by path or UUID`() {
        let folder = CaptureSourceDescriptor.folder(URL(fileURLWithPath: "/Users/me/Steam Deck/"))
        let volume = CaptureSourceDescriptor.volume(URL(fileURLWithPath: "/Volumes/PS5"), name: "PS5", uuid: "ABCD-1234")
        let unnamedVolume = CaptureSourceDescriptor.volume(URL(fileURLWithPath: "/Volumes/CARD"), name: "CARD", uuid: nil)

        #expect(folder.id == "folder:/Users/me/Steam Deck")
        #expect(folder.name == "Steam Deck")
        #expect(folder.kind == .folder)
        #expect(volume.id == "volume:ABCD-1234")
        #expect(unnamedVolume.id == "volume:/Volumes/CARD")
        #expect(volume.kind == .volume)
        #expect(!volume.kind.isUSB)
        #expect(CaptureSourceDescriptor.Kind.camera.isUSB)
        #expect(Set([folder, volume, folder]).count == 2)
    }

    @Test
    func `Log lines name a USB device but only the kind of a drive or folder, whose path is private`() {
        let console = USBMTPTransport.DeviceID(vendorID: 0x057E, productID: 0x2061, name: "Nintendo Switch 2", locationID: 0x1420_0000).descriptor
        let folder = CaptureSourceDescriptor.folder(URL(fileURLWithPath: "/Users/me/Family Trip/"))
        let volume = CaptureSourceDescriptor.volume(URL(fileURLWithPath: "/Volumes/JANE'S SD"), name: "JANE'S SD", uuid: nil)

        #expect(console.logName == "console Nintendo Switch 2")
        #expect(console.logDetail == nil)
        #expect(folder.logName == "folder")
        #expect(folder.logDetail == "/Users/me/Family Trip")
        #expect(volume.logName == "volume")
        #expect(volume.logDetail == "/Volumes/JANE'S SD")
    }
}
