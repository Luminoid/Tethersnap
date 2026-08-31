import Foundation
import IOKit
import IOUSBHost

/// `MTPTransport` over IOUSBHost: finds the console, claims its MTP interface,
/// and drives the bulk pipes synchronously.
///
/// macOS has no MTP kernel driver, so the device service is unclaimed and a
/// user-space client can take exclusive ownership without entitlements
/// (outside the App Sandbox).
public final class USBMTPTransport: MTPTransport {
    /// USB identity of a supported console.
    public struct DeviceID: Sendable {
        public let vendorID: UInt16
        public let productID: UInt16
        public let name: String

        public init(vendorID: UInt16, productID: UInt16, name: String) {
            self.vendorID = vendorID
            self.productID = productID
            self.name = name
        }

        /// Nintendo Switch 2 in Copy-to-PC mode (057e:2061).
        public static let switch2 = Self(vendorID: 0x057E, productID: 0x2061, name: "Nintendo Switch 2")
        /// Original Nintendo Switch / Switch Lite (057e:201d), same protocol.
        public static let switch1 = Self(vendorID: 0x057E, productID: 0x201D, name: "Nintendo Switch")

        public static let supported: [Self] = [.switch2, .switch1]
    }

    /// Descriptor summary of the claimed interface, for `tethersnap probe`.
    public struct InterfaceSummary {
        public let interfaceNumber: Int
        public let interfaceClass: Int
        public let interfaceSubclass: Int
        public let interfaceProtocol: Int
        public let bulkInAddress: Int
        public let bulkOutAddress: Int
        public let interruptInAddress: Int?
    }

    public let deviceID: DeviceID
    public private(set) var interfaceSummary: InterfaceSummary?

    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let bulkInPipe: IOUSBHostPipe
    private let bulkOutPipe: IOUSBHostPipe
    private var isDestroyed = false

    // MARK: - Discovery

    /// Whether a supported console is currently attached in MTP mode.
    public static func attachedDeviceID() -> DeviceID? {
        for deviceID in DeviceID.supported {
            let service = locateService(for: deviceID)
            if service != IO_OBJECT_NULL {
                IOObjectRelease(service)
                return deviceID
            }
        }
        TethersnapLog.debug(TethersnapLog.usb, "no supported console in the IO registry "
            + "(looked for \(DeviceID.supported.map { String(format: "%04x:%04x", $0.vendorID, $0.productID) }.joined(separator: ", ")))")
        return nil
    }

    private static func locateService(for deviceID: DeviceID) -> io_service_t {
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: deviceID.vendorID),
            productID: NSNumber(value: deviceID.productID),
            bcdDevice: nil,
            deviceClass: nil,
            deviceSubclass: nil,
            deviceProtocol: nil,
            speed: nil,
            productIDArray: nil
        )
        // IOServiceGetMatchingService consumes the dictionary's +1 reference.
        return IOServiceGetMatchingService(kIOMainPortDefault, matching.takeUnretainedValue())
    }

    // MARK: - Init / teardown

    /// Find and claim the first attached supported console.
    public convenience init() throws {
        guard let found = Self.attachedDeviceID() else {
            throw MTPError.deviceNotFound
        }
        try self.init(deviceID: found)
    }

    public init(deviceID: DeviceID) throws {
        self.deviceID = deviceID

        let service = Self.locateService(for: deviceID)
        guard service != IO_OBJECT_NULL else { throw MTPError.deviceNotFound }

        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw MTPError.claimFailed("opening the device (is another MTP app running?)", underlying: error)
        }

        // A throwing class init skips deinit, so the catch below must tear down
        // everything claimed so far explicitly (a leaked exclusive interface
        // claim poisons the next connect attempt).
        var claimedInterface: IOUSBHostInterface?
        do {
            try Self.ensureConfigured(device)
            let candidate = try Self.findMTPInterface(in: device)
            let claimed = try Self.claimInterface(deviceID: deviceID, candidate: candidate)
            claimedInterface = claimed
            let pipes = try Self.openPipes(on: claimed, candidate: candidate)
            interface = claimed
            bulkInPipe = pipes.bulkIn
            bulkOutPipe = pipes.bulkOut
            interfaceSummary = InterfaceSummary(
                interfaceNumber: candidate.interfaceNumber,
                interfaceClass: candidate.interfaceClass,
                interfaceSubclass: candidate.interfaceSubclass,
                interfaceProtocol: candidate.interfaceProtocol,
                bulkInAddress: candidate.bulkInAddress,
                bulkOutAddress: candidate.bulkOutAddress,
                interruptInAddress: candidate.interruptInAddress
            )
            TethersnapLog.info(TethersnapLog.usb, String(
                format: "claimed %@ (%04x:%04x) interface #%d class 0x%02X, bulk-in 0x%02X bulk-out 0x%02X",
                deviceID.name, deviceID.vendorID, deviceID.productID,
                candidate.interfaceNumber, candidate.interfaceClass,
                candidate.bulkInAddress, candidate.bulkOutAddress
            ))
        } catch {
            TethersnapLog.error(TethersnapLog.usb, "claim failed for \(deviceID.name): \(error.localizedDescription)")
            claimedInterface?.destroy()
            device.destroy()
            throw error
        }
    }

    deinit {
        shutdown()
    }

    /// Release the interface and device services.
    public func shutdown() {
        guard !isDestroyed else { return }
        isDestroyed = true
        interface.destroy()
        device.destroy()
        TethersnapLog.info(TethersnapLog.usb, "released \(deviceID.name)")
    }

    // MARK: - MTPTransport

    /// Reused bulk-in buffer; growing zero-fills once instead of allocating and
    /// zeroing a fresh chunk per transfer. The transport is driven from a single
    /// thread (the session serializes), so plain storage is safe.
    private let reusableReadBuffer = NSMutableData()

    public func bulkOut(_ data: Data, timeout: TimeInterval) throws {
        let buffer = NSMutableData(data: data)
        var transferred = 0
        do {
            try bulkOutPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            TethersnapLog.error(TethersnapLog.usb, "bulk-out failed after \(transferred)/\(data.count) bytes: \(error.localizedDescription)")
            recoverFromStall(after: error)
            throw MTPError.transferFailed(underlying: error)
        }
        TethersnapLog.debug(TethersnapLog.usb, "bulk-out \(TethersnapLog.hexPreview(data))")
        guard transferred == data.count else {
            throw MTPError.malformedData("bulk-out wrote \(transferred) of \(data.count) bytes")
        }
    }

    public func bulkIn(maxLength: Int, timeout: TimeInterval) throws -> Data {
        let buffer = reusableReadBuffer
        buffer.length = maxLength
        var transferred = 0
        do {
            try bulkInPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            TethersnapLog.error(TethersnapLog.usb, "bulk-in failed (requested \(maxLength)): \(error.localizedDescription)")
            recoverFromStall(after: error)
            throw MTPError.transferFailed(underlying: error)
        }
        let data = Data(bytes: buffer.bytes, count: transferred)
        TethersnapLog.debug(TethersnapLog.usb, "bulk-in \(TethersnapLog.hexPreview(data))")
        return data
    }

    /// PIMA 15740 USB-class Device Reset on the control endpoint: cancels any
    /// open session responder-side and returns it to Idle. The only way to
    /// clear a stale session whose transaction counter we don't know (left by
    /// a killed CLI run or another PTP client, e.g. macOS's own ptpcamerad).
    public func deviceReset() throws {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x21 // host-to-device, class, interface
        request.bRequest = 0x66 // Device Reset Request
        request.wValue = 0
        request.wIndex = UInt16(interfaceSummary?.interfaceNumber ?? 0)
        request.wLength = 0
        var transferred = 0
        do {
            try interface.__send(request, data: nil, bytesTransferred: &transferred, completionTimeout: 5)
            TethersnapLog.info(TethersnapLog.usb, "sent class Device Reset to \(deviceID.name)")
        } catch {
            TethersnapLog.error(TethersnapLog.usb, "class Device Reset failed "
                + "(0x\(String(format: "%08X", (error as NSError).code))): \(error.localizedDescription)")
            throw MTPError.transferFailed(underlying: error)
        }
    }

    /// USB device reset: terminates this device object kernel-side and
    /// re-enumerates the console, a software replug. The only reliable cure
    /// for a stale session on the Switch 2, which STALLs the class Device
    /// Reset (observed fw 22.5.0). This transport is dead afterwards; the
    /// console re-attaches fresh and the caller reconnects.
    public func hardReset() {
        do {
            try device.reset()
            TethersnapLog.info(TethersnapLog.usb, "USB device reset issued; \(deviceID.name) will re-enumerate")
        } catch {
            TethersnapLog.error(TethersnapLog.usb, "USB device reset failed: \(error.localizedDescription)")
        }
        shutdown()
    }

    /// A failed transfer can leave a bulk endpoint halted; clearing the stall
    /// gives the next session a clean pipe. Only an actual stall gets cleared
    /// (clearing a healthy pipe resets its data toggle); timeouts and cable
    /// pulls are left alone. The current transaction is lost either way, so
    /// callers reconnect rather than retry blind.
    private func recoverFromStall(after error: Error) {
        guard Self.isPipeStall(error) else { return }
        TethersnapLog.info(TethersnapLog.usb, "clearing stalled bulk pipes")
        try? bulkInPipe.clearStall()
        try? bulkOutPipe.clearStall()
    }

    /// kIOUSBPipeStalled (0xe0004007); the IOReturn may arrive sign-extended.
    private static func isPipeStall(_ error: Error) -> Bool {
        Int32(truncatingIfNeeded: (error as NSError).code) == Int32(bitPattern: 0xE000_4007)
    }

    // MARK: - USB plumbing

    private struct InterfaceCandidate {
        let interfaceNumber: Int
        let configurationValue: Int
        let interfaceClass: Int
        let interfaceSubclass: Int
        let interfaceProtocol: Int
        let bulkInAddress: Int
        let bulkOutAddress: Int
        let interruptInAddress: Int?
    }

    private static func ensureConfigured(_ device: IOUSBHostDevice) throws {
        if device.configurationDescriptor != nil { return }
        guard let descriptor = try? device.configurationDescriptor(with: 0) else {
            throw MTPError.claimFailed("reading the configuration descriptor", underlying: nil)
        }
        do {
            try device.__configure(withValue: Int(descriptor.pointee.bConfigurationValue), matchInterfaces: true)
        } catch {
            throw MTPError.claimFailed("selecting configuration \(descriptor.pointee.bConfigurationValue)", underlying: error)
        }
    }

    /// Walk the active configuration for an interface with a bulk-in/bulk-out
    /// pair, preferring still-image (0x06) and vendor-specific (0xFF) classes.
    private static func findMTPInterface(in device: IOUSBHostDevice) throws -> InterfaceCandidate {
        guard let configuration = device.configurationDescriptor else {
            throw MTPError.claimFailed("device has no active configuration", underlying: nil)
        }

        // Seed before the loop, advance at the END, exit on nil. The previous
        // `current.flatMap { next } ?? getFirst()` shape restarted the walk
        // from the beginning whenever the iterator was exhausted (flatMap's
        // nil falls into the ?? branch), which spun forever against the real
        // console's descriptors. Never reintroduce a restart path here.
        var candidates: [InterfaceCandidate] = []
        var interfacePointer = IOUSBGetNextInterfaceDescriptor(configuration, nil)
        while let interfaceDescriptor = interfacePointer {
            var bulkIn: Int?
            var bulkOut: Int?
            var interruptIn: Int?
            var endpointPointer = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, nil)
            while let endpoint = endpointPointer {
                let address = Int(endpoint.pointee.bEndpointAddress)
                let isInput = address & 0x80 != 0
                switch endpoint.pointee.bmAttributes & 0x03 {
                case 2: // bulk
                    if isInput { bulkIn = bulkIn ?? address } else { bulkOut = bulkOut ?? address }
                case 3 where isInput: // interrupt
                    interruptIn = interruptIn ?? address
                default:
                    break
                }
                endpointPointer = endpoint.withMemoryRebound(to: IOUSBDescriptorHeader.self, capacity: 1) {
                    IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, $0)
                }
            }

            if let bulkIn, let bulkOut {
                candidates.append(InterfaceCandidate(
                    interfaceNumber: Int(interfaceDescriptor.pointee.bInterfaceNumber),
                    configurationValue: Int(configuration.pointee.bConfigurationValue),
                    interfaceClass: Int(interfaceDescriptor.pointee.bInterfaceClass),
                    interfaceSubclass: Int(interfaceDescriptor.pointee.bInterfaceSubClass),
                    interfaceProtocol: Int(interfaceDescriptor.pointee.bInterfaceProtocol),
                    bulkInAddress: bulkIn,
                    bulkOutAddress: bulkOut,
                    interruptInAddress: interruptIn
                ))
            }
            interfacePointer = interfaceDescriptor.withMemoryRebound(to: IOUSBDescriptorHeader.self, capacity: 1) {
                IOUSBGetNextInterfaceDescriptor(configuration, $0)
            }
        }
        for candidate in candidates {
            TethersnapLog.debug(TethersnapLog.usb, String(
                format: "interface candidate #%d class 0x%02X bulk-in 0x%02X bulk-out 0x%02X",
                candidate.interfaceNumber, candidate.interfaceClass, candidate.bulkInAddress, candidate.bulkOutAddress
            ))
        }

        let preferredClasses = [0x06, 0xFF]
        let best = candidates.first { preferredClasses.contains($0.interfaceClass) } ?? candidates.first
        guard let best else { throw MTPError.noMTPInterface }
        return best
    }

    /// Interfaces register asynchronously after configuration, so poll briefly.
    private static func claimInterface(deviceID: DeviceID, candidate: InterfaceCandidate) throws -> IOUSBHostInterface {
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        repeat {
            let matching = IOUSBHostInterface.__createMatchingDictionary(
                withVendorID: NSNumber(value: deviceID.vendorID),
                productID: NSNumber(value: deviceID.productID),
                bcdDevice: nil,
                interfaceNumber: NSNumber(value: candidate.interfaceNumber),
                configurationValue: NSNumber(value: candidate.configurationValue),
                interfaceClass: nil,
                interfaceSubclass: nil,
                interfaceProtocol: nil,
                speed: nil,
                productIDArray: nil
            )
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching.takeUnretainedValue())
            if service != IO_OBJECT_NULL {
                do {
                    return try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
                } catch {
                    lastError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw MTPError.claimFailed("claiming interface \(candidate.interfaceNumber)", underlying: lastError)
    }

    private static func openPipes(on interface: IOUSBHostInterface,
                                  candidate: InterfaceCandidate) throws -> (bulkIn: IOUSBHostPipe, bulkOut: IOUSBHostPipe) {
        do {
            let bulkIn = try interface.copyPipe(withAddress: candidate.bulkInAddress)
            let bulkOut = try interface.copyPipe(withAddress: candidate.bulkOutAddress)
            return (bulkIn, bulkOut)
        } catch {
            throw MTPError.claimFailed("opening bulk pipes", underlying: error)
        }
    }
}
