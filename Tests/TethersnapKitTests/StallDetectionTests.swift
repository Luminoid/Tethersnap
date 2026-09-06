import Foundation
import Testing
@testable import TethersnapKit

@Suite("Pipe stall detection")
struct StallDetectionTests {
    private func ioReturn(_ code: UInt32, signExtended: Bool = false) -> NSError {
        let value = signExtended ? Int(Int32(bitPattern: code)) : Int(code)
        return NSError(domain: NSOSStatusErrorDomain, code: value)
    }

    @Test
    func `IOUSBHost stall code is recognized whether or not it arrives sign-extended`() {
        #expect(USBMTPTransport.isPipeStall(ioReturn(0xE000_5000)))
        #expect(USBMTPTransport.isPipeStall(ioReturn(0xE000_5000, signExtended: true)))
    }

    @Test
    func `Legacy IOUSBFamily stall codes are recognized`() {
        #expect(USBMTPTransport.isPipeStall(ioReturn(0xE000_404F)))
        #expect(USBMTPTransport.isPipeStall(ioReturn(0xE000_4007, signExtended: true)))
    }

    @Test
    func `Unrelated errors are not treated as stalls`() {
        #expect(!USBMTPTransport.isPipeStall(ioReturn(0xE000_4051)))
        #expect(!USBMTPTransport.isPipeStall(NSError(domain: NSCocoaErrorDomain, code: 0)))
    }
}
