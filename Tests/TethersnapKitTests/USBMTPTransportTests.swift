import Foundation
import Testing
@testable import TethersnapKit

/// The transport's pure predicates: IOKit return codes arrive as `NSError`
/// codes that may or may not be sign-extended, and the macros do not import.
@Suite("USB transport predicates")
struct USBMTPTransportTests {
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

    @Test
    func `kIOReturnExclusiveAccess is recognized whether or not it arrives sign-extended`() {
        #expect(USBMTPTransport.isExclusiveAccess(ioReturn(0xE000_02C5)))
        #expect(USBMTPTransport.isExclusiveAccess(ioReturn(0xE000_02C5, signExtended: true)))
        #expect(!USBMTPTransport.isExclusiveAccess(ioReturn(0xE000_02C2))) // kIOReturnNotOpen
        #expect(!USBMTPTransport.isExclusiveAccess(ioReturn(0xE000_5000)))
        #expect(!USBMTPTransport.isExclusiveAccess(NSError(domain: NSCocoaErrorDomain, code: 0)))
    }
}
