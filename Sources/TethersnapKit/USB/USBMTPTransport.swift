import Foundation
import IOKit
import IOUSBHost

/// `MTPTransport` over IOUSBHost: finds a PTP device, claims its still-image
/// (or vendor-specific) interface, and drives the bulk pipes synchronously.
///
/// macOS has no MTP kernel driver, so the device service is unclaimed and a
/// user-space client can take exclusive ownership without entitlements
/// (outside the App Sandbox).
public final class USBMTPTransport: MTPTransport {
    /// USB identity of an attached PTP device (or a table entry for a known console).
    public struct DeviceID: Sendable, Hashable {
        public let vendorID: UInt16
        public let productID: UInt16
        public let name: String
        /// The device's `locationID` registry property: its position in the USB
        /// topology, stable per port and across a USB reset. nil only in the
        /// static table; every discovered ID carries one.
        public let locationID: UInt32?
        public let serialNumber: String?
        public let kind: CaptureSourceDescriptor.Kind

        public init(vendorID: UInt16, productID: UInt16, name: String,
                    locationID: UInt32? = nil, serialNumber: String? = nil, kind: CaptureSourceDescriptor.Kind = .console) {
            self.vendorID = vendorID
            self.productID = productID
            self.name = name
            self.locationID = locationID
            self.serialNumber = serialNumber
            self.kind = kind
        }

        /// Nintendo Switch 2 in Copy-to-PC mode (057e:2061).
        public static let switch2 = Self(vendorID: 0x057E, productID: 0x2061, name: "Nintendo Switch 2")
        /// Original Nintendo Switch / Switch Lite (057e:201d), same protocol.
        public static let switch1 = Self(vendorID: 0x057E, productID: 0x201D, name: "Nintendo Switch")

        /// Consoles known by vendor/product ID. They are also found by their
        /// still-image interface; the table supplies the friendly name, the
        /// console kind, and discovery before the interface nub exists.
        public static let supported: [Self] = [.switch2, .switch1]

        /// The table entry for a vendor/product pair, nil for anything else.
        public static func known(vendorID: UInt16, productID: UInt16) -> Self? {
            supported.first { $0.vendorID == vendorID && $0.productID == productID }
        }

        /// `vvvv:pppp`, for logs, ids, and the pre-connect detail line.
        public var hexPair: String {
            String(format: "%04x:%04x", vendorID, productID)
        }

        public var descriptor: CaptureSourceDescriptor {
            CaptureSourceDescriptor(
                id: "usb:\(String(format: "%08x", locationID ?? 0)):\(hexPair)",
                name: name,
                kind: kind,
                detail: hexPair,
                location: .usb(self)
            )
        }
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

    /// Every attached PTP device: still-image-class (0x06) interfaces, which
    /// cover cameras, phones, and both Switches, unioned with the known console
    /// IDs at device level (a console can sit unconfigured with no interface
    /// nub yet). Consoles first, then by USB location.
    public static func attachedDevices() -> [DeviceID] {
        var found: [DeviceID] = []
        var seenLocations = Set<UInt32>()
        func add(_ id: DeviceID) {
            guard let location = id.locationID, seenLocations.insert(location).inserted else { return }
            found.append(id)
        }
        forEachService(matching: stillImageInterfaceMatching()) { service in
            if let id = deviceID(forService: service) { add(id) }
        }
        for known in DeviceID.supported {
            forEachService(matching: deviceMatching(vendorID: known.vendorID, productID: known.productID)) { service in
                if let id = deviceID(forService: service) { add(id) }
            }
        }
        found.sort { lhs, rhs in
            if (lhs.kind == .console) != (rhs.kind == .console) { return lhs.kind == .console }
            return (lhs.locationID ?? 0) < (rhs.locationID ?? 0)
        }
        // The app polls this every few seconds; log transitions, not every poll.
        if found.isEmpty {
            TethersnapLog.resetOnce(discoveryHitKey)
            TethersnapLog.once(discoveryMissKey, .debug, .usb, "no PTP device in the IO registry")
        } else {
            TethersnapLog.resetOnce(discoveryMissKey)
            TethersnapLog.once(discoveryHitKey, .debug, .usb, "present in the IO registry: \(found.map { "\($0.name) (\($0.hexPair))" }.joined(separator: ", "))")
        }
        return found
    }

    private static let discoveryHitKey = "usb.discovery.hit"
    private static let discoveryMissKey = "usb.discovery.miss"

    /// The device service for `deviceID`: among the vendor/product matches, the
    /// one at its USB location (two identical cameras stay distinct), or the
    /// first when the ID is a bare table entry. Returned retained (+1).
    private static func locateService(for deviceID: DeviceID) -> io_service_t {
        var match: io_service_t = IO_OBJECT_NULL
        forEachService(matching: deviceMatching(vendorID: deviceID.vendorID, productID: deviceID.productID)) { service in
            guard match == IO_OBJECT_NULL else { return }
            if let wanted = deviceID.locationID, registryUInt32(service, RegistryKey.locationID) != wanted { return }
            IOObjectRetain(service)
            match = service
        }
        return match
    }

    // MARK: - Init / teardown

    public init(deviceID: DeviceID) throws {
        self.deviceID = deviceID

        let service = Self.locateService(for: deviceID)
        guard service != IO_OBJECT_NULL else { throw MTPError.deviceNotFound }
        // `locateService` hands back a +1 reference; the IOUSBHost object keeps
        // its own, so ours is released whether or not the open succeeds.
        defer { IOObjectRelease(service) }

        do {
            device = try Self.openDevice(service, deviceID: deviceID)
        } catch {
            TethersnapLog.error(.usb, "opening \(deviceID.name) failed", error: error)
            throw error
        }

        // A throwing class init skips deinit, so the catch below must tear down
        // everything claimed so far explicitly (a leaked exclusive interface
        // claim poisons the next connect attempt).
        var claimedInterface: IOUSBHostInterface?
        do {
            try Self.ensureConfigured(device)
            let candidate = try Self.findMTPInterface(in: device)
            let claimed = try Self.claimInterface(on: device, candidate: candidate)
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
            TethersnapLog.notice(.usb, String(
                format: "claimed %@ (%04x:%04x) interface #%d class 0x%02X, bulk-in 0x%02X bulk-out 0x%02X",
                deviceID.name, deviceID.vendorID, deviceID.productID,
                candidate.interfaceNumber, candidate.interfaceClass,
                candidate.bulkInAddress, candidate.bulkOutAddress
            ))
        } catch {
            // Log the stage and the IOUSBHost error directly: an error summary does not
            // reach inside claimFailed's payload, and the IOReturn code is the useful part.
            if case let MTPError.claimFailed(stage, underlying) = error {
                TethersnapLog.error(.usb, "claim failed for \(deviceID.name) (stage: \(stage))", error: underlying)
            } else {
                TethersnapLog.error(.usb, "claim failed for \(deviceID.name)", error: error)
            }
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
        TethersnapLog.notice(.usb, "released \(deviceID.name)")
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
            TethersnapLog.error(.usb, "bulk-out failed after \(transferred)/\(data.count) bytes (timeout \(Int(timeout)) s)", error: error)
            recoverFromStall(after: error)
            throw MTPError.transferFailed(underlying: error)
        }
        TethersnapLog.debug(.usb, "bulk-out \(TethersnapLog.hexPreview(data))")
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
            TethersnapLog.error(.usb, "bulk-in failed after \(transferred)/\(maxLength) bytes (timeout \(Int(timeout)) s)", error: error)
            recoverFromStall(after: error)
            throw MTPError.transferFailed(underlying: error)
        }
        // Clamped so an over-reported transfer count can never read past the buffer.
        let data = Data(bytes: buffer.bytes, count: min(transferred, maxLength))
        TethersnapLog.debug(.usb, "bulk-in \(TethersnapLog.hexPreview(data))")
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
            TethersnapLog.notice(.usb, "sent class Device Reset to \(deviceID.name)")
        } catch {
            // The caller escalates to a USB device reset, so this is a recovery step, not the end.
            TethersnapLog.warning(.usb, "class Device Reset failed (0x\(String(format: "%08X", (error as NSError).code)))", error: error)
            throw MTPError.transferFailed(underlying: error)
        }
    }

    /// USB device reset: terminates this device object kernel-side and
    /// re-enumerates the device, a software replug. The only reliable cure
    /// for a stale session on the Switch 2, which STALLs the class Device
    /// Reset (observed fw 22.5.0). This transport is dead afterwards; the
    /// device re-attaches fresh and the caller reconnects.
    public func hardReset() {
        do {
            try device.reset()
            TethersnapLog.notice(.usb, "USB device reset issued; \(deviceID.name) will re-enumerate")
        } catch {
            TethersnapLog.error(.usb, "USB device reset failed", error: error)
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
        TethersnapLog.warning(.usb, "clearing stalled bulk pipes")
        Self.clearStall(on: bulkInPipe, label: "bulk-in", address: interfaceSummary?.bulkInAddress)
        Self.clearStall(on: bulkOutPipe, label: "bulk-out", address: interfaceSummary?.bulkOutAddress)
    }

    private static func clearStall(on pipe: IOUSBHostPipe, label: String, address: Int?) {
        do {
            try pipe.clearStall()
        } catch {
            let endpoint = address.map { String(format: " 0x%02X", $0) } ?? ""
            TethersnapLog.warning(.usb, "clearStall on \(label)\(endpoint) failed", error: error)
        }
    }

    /// IOUSBHost reports a STALL handshake as `kUSBHostReturnPipeStalled`
    /// (0xe0005000, IOUSBHostFamilyDefinitions.h: "Use clearStall to clear this
    /// condition"). The legacy IOUSBFamily stall codes are accepted too
    /// (0xe000404f kIOUSBPipeStalled, 0xe0004007 kIOUSBWrongPIDErr "Pipe stall,
    /// Bad or wrong PID"); the first release matched only the latter, so a real
    /// stall never cleared. The macros don't import into Swift, and the IOReturn
    /// may arrive sign-extended in the NSError code.
    static func isPipeStall(_ error: Error) -> Bool {
        stallCodes.contains(Int32(truncatingIfNeeded: (error as NSError).code))
    }

    private static let stallCodes: [Int32] = [0xE000_5000, 0xE000_404F, 0xE000_4007].map { Int32(bitPattern: $0) }

    // MARK: - USB plumbing

    private struct InterfaceCandidate {
        let interfaceNumber: Int
        let interfaceClass: Int
        let interfaceSubclass: Int
        let interfaceProtocol: Int
        let bulkInAddress: Int
        let bulkOutAddress: Int
        let interruptInAddress: Int?
    }

    private static func ensureConfigured(_ device: IOUSBHostDevice) throws {
        if device.configurationDescriptor != nil { return }
        let descriptor: UnsafePointer<IOUSBConfigurationDescriptor>
        do {
            descriptor = try device.configurationDescriptor(with: 0)
        } catch {
            // Logged once, by the init's claim catch, with this stage and the error.
            throw MTPError.claimFailed("reading the configuration descriptor", underlying: error)
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
            TethersnapLog.debug(.usb, String(
                format: "interface candidate #%d class 0x%02X bulk-in 0x%02X bulk-out 0x%02X",
                candidate.interfaceNumber, candidate.interfaceClass, candidate.bulkInAddress, candidate.bulkOutAddress
            ))
        }

        let preferredClasses = [0x06, 0xFF]
        let best = candidates.first { preferredClasses.contains($0.interfaceClass) } ?? candidates.first
        guard let best else { throw MTPError.noMTPInterface }
        return best
    }

    /// How long a claim keeps retrying: interfaces register asynchronously
    /// after configuration, and a holder of exclusive access (ptpcamerad on
    /// behalf of Image Capture or Photos) may let go within a few seconds.
    private static let claimDeadline: TimeInterval = 5

    /// Open the device service, retrying while another client holds
    /// exclusive access; past the deadline that becomes `deviceBusy`.
    private static func openDevice(_ service: io_service_t, deviceID: DeviceID) throws -> IOUSBHostDevice {
        let deadline = Date().addingTimeInterval(claimDeadline)
        var lastError: Error?
        repeat {
            do {
                return try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            } catch {
                lastError = error
                guard isExclusiveAccess(error) else { break }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        if let lastError, isExclusiveAccess(lastError) {
            throw MTPError.deviceBusy(underlying: lastError)
        }
        throw MTPError.claimFailed("opening the device (is another MTP app running?)", underlying: lastError)
    }

    /// Claim the candidate interface among the opened device's own children
    /// (never a bus-wide vendor/product match: two identical cameras would be
    /// ambiguous), polling until the deadline.
    private static func claimInterface(on device: IOUSBHostDevice, candidate: InterfaceCandidate) throws -> IOUSBHostInterface {
        let deadline = Date().addingTimeInterval(claimDeadline)
        var lastError: Error?
        repeat {
            if let service = interfaceService(of: device, interfaceNumber: candidate.interfaceNumber) {
                // The child iterator handed back a +1 reference; release it on
                // every path, or a 5 s busy wait leaks fifty port rights.
                defer { IOObjectRelease(service) }
                do {
                    return try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
                } catch {
                    lastError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        if let lastError, isExclusiveAccess(lastError) {
            throw MTPError.deviceBusy(underlying: lastError)
        }
        throw MTPError.claimFailed("claiming interface \(candidate.interfaceNumber)", underlying: lastError)
    }

    /// The device's child `IOUSBHostInterface` with `bInterfaceNumber ==
    /// interfaceNumber`, retained (+1), or nil while it has not registered yet.
    /// Other children (user clients of other processes) are skipped by class.
    private static func interfaceService(of device: IOUSBHostDevice, interfaceNumber: Int) -> io_service_t? {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(device.ioService, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            if IOObjectConformsTo(child, RegistryKey.interfaceClassName) != 0,
               registryUInt32(child, RegistryKey.interfaceNumber) == UInt32(interfaceNumber) {
                return child
            }
            IOObjectRelease(child)
        }
        return nil
    }

    /// `kIOReturnExclusiveAccess` (0xe00002c5): another client owns the
    /// device or interface. Sign-tolerant like `isPipeStall`.
    static func isExclusiveAccess(_ error: Error) -> Bool {
        Int32(truncatingIfNeeded: (error as NSError).code) == Int32(bitPattern: 0xE000_02C5)
    }

    // MARK: - IO registry

    /// Registry property names (IOUSBHostFamilyDefinitions.h; the string
    /// descriptors keep their legacy `kUSB…String` names as property keys).
    enum RegistryKey {
        static let vendorID = "idVendor"
        static let productID = "idProduct"
        static let locationID = "locationID"
        static let interfaceNumber = "bInterfaceNumber"
        static let productString = "kUSBProductString"
        static let vendorString = "kUSBVendorString"
        static let serialNumberString = "kUSBSerialNumberString"
        static let interfaceClassName = "IOUSBHostInterface"
        /// USB still-image class: PTP responders (PIMA 15740 / MTP).
        static let stillImageClass = 6
        /// Apple's vendor ID: iPhones and iPads expose a PTP interface too.
        static let appleVendorID: UInt16 = 0x05AC
    }

    /// Matching dictionary for every still-image-class interface on the bus.
    /// Each IOKit call that takes one consumes its +1 reference, so callers
    /// create a fresh dictionary per call.
    static func stillImageInterfaceMatching() -> Unmanaged<CFMutableDictionary> {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: NSNumber(value: RegistryKey.stillImageClass),
            interfaceSubclass: nil,
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil
        )
    }

    /// Matching dictionary for a device by vendor/product ID.
    static func deviceMatching(vendorID: UInt16, productID: UInt16) -> Unmanaged<CFMutableDictionary> {
        IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID),
            productID: NSNumber(value: productID),
            bcdDevice: nil,
            deviceClass: nil,
            deviceSubclass: nil,
            deviceProtocol: nil,
            speed: nil,
            productIDArray: nil
        )
    }

    /// Run `body` on every service matching `dictionary` (consumed), each
    /// released after the call; `body` retains what it wants to keep.
    private static func forEachService(matching dictionary: Unmanaged<CFMutableDictionary>, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary.takeUnretainedValue(), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// The identity of a device or interface service: an interface resolves
    /// to its parent device. Known consoles get their table name and kind;
    /// anything else is named by its product string and is a camera unless
    /// Apple made it.
    static func deviceID(forService service: io_service_t) -> DeviceID? {
        var deviceService = service
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        if IOObjectConformsTo(service, RegistryKey.interfaceClassName) != 0 {
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            deviceService = parent
        }
        defer { if parent != IO_OBJECT_NULL { IOObjectRelease(parent) } }

        guard let vendor = registryUInt32(deviceService, RegistryKey.vendorID),
              let product = registryUInt32(deviceService, RegistryKey.productID) else { return nil }
        let vendorID = UInt16(truncatingIfNeeded: vendor)
        let productID = UInt16(truncatingIfNeeded: product)
        let locationID = registryUInt32(deviceService, RegistryKey.locationID)
        let serial = registryString(deviceService, RegistryKey.serialNumberString)
        if let known = DeviceID.known(vendorID: vendorID, productID: productID) {
            return DeviceID(vendorID: vendorID, productID: productID, name: known.name,
                            locationID: locationID, serialNumber: serial, kind: known.kind)
        }
        let name = registryString(deviceService, RegistryKey.productString)
            ?? registryString(deviceService, RegistryKey.vendorString).map { "\($0) \(String(format: "%04x:%04x", vendorID, productID))" }
            ?? String(format: "PTP device %04x:%04x", vendorID, productID)
        return DeviceID(vendorID: vendorID, productID: productID, name: name,
                        locationID: locationID, serialNumber: serial,
                        kind: vendorID == RegistryKey.appleVendorID ? .ptpDevice : .camera)
    }

    private static func registryUInt32(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = value as? NSNumber else { return nil }
        return UInt32(truncatingIfNeeded: number.int64Value)
    }

    private static func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let string = value as? String, !string.isEmpty else { return nil }
        return string
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
