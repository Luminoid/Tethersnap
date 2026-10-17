import Foundation
import IOKit

/// Push notifications for PTP device arrival/removal via IOKit matching
/// notifications, so the app reacts immediately instead of only on a poll.
///
/// Watches every still-image-class interface (cameras, phones, both Switches)
/// plus the known console IDs at device level, so a console is seen before
/// its interface nub registers. A device that matches more than once (its
/// interface and, for a console, the device itself) is reported once per
/// USB location.
///
/// Events are delivered on an internal serial queue; the handler must be
/// `@Sendable` and hop to wherever it needs to go. Call `invalidate()` before
/// letting the last reference go: it fences the callback queue.
public final class USBDeviceWatcher: @unchecked Sendable {
    public enum Event: Sendable {
        case attached(USBMTPTransport.DeviceID)
        case removed(USBMTPTransport.DeviceID)
    }

    private final class Registration {
        /// Weak: a callback racing the watcher's release must find nil, not a
        /// dangling reference.
        weak var watcher: USBDeviceWatcher?
        let isArrival: Bool
        var iterator: io_iterator_t = IO_OBJECT_NULL

        init(watcher: USBDeviceWatcher, isArrival: Bool) {
            self.watcher = watcher
            self.isArrival = isArrival
        }
    }

    private let queue = DispatchQueue(label: "dev.luminoid.Tethersnap.USBDeviceWatcher")
    private let handler: @Sendable (Event) -> Void
    private let notifyPort: IONotificationPortRef
    private var registrations: [Registration] = []
    private var isInvalidated = false
    /// Live registry entries per USB location, so the second match for one
    /// device adds no event and removal fires when the last entry goes.
    private var entriesByLocation: [UInt32: Set<UInt64>] = [:]
    /// Identity captured at arrival: a terminated service's properties are
    /// not reliably readable any more.
    private var deviceByEntry: [UInt64: USBMTPTransport.DeviceID] = [:]

    /// Start watching still-image interfaces and every known console ID.
    public init?(handler: @escaping @Sendable (Event) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            TethersnapLog.warning(.usb, "IONotificationPortCreate failed; device watcher unavailable, devices are found by polling only")
            return nil
        }
        self.handler = handler
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        // On the queue: arming a registration drains it here, and a match for an
        // earlier registration may already be firing on the queue. Every mutation
        // of the dictionaries stays queue-confined that way.
        queue.sync {
            register(label: "still-image interfaces", isArrival: true, type: kIOFirstMatchNotification, matching: USBMTPTransport.stillImageInterfaceMatching)
            register(label: "still-image interfaces", isArrival: false, type: kIOTerminatedNotification, matching: USBMTPTransport.stillImageInterfaceMatching)
            for deviceID in USBMTPTransport.DeviceID.supported {
                let matching = { USBMTPTransport.deviceMatching(vendorID: deviceID.vendorID, productID: deviceID.productID) }
                register(label: deviceID.name, isArrival: true, type: kIOFirstMatchNotification, matching: matching)
                register(label: deviceID.name, isArrival: false, type: kIOTerminatedNotification, matching: matching)
            }
        }
        guard !registrations.isEmpty else {
            // Every stored property is set, so returning nil runs `deinit`,
            // which destroys the port; destroying it here too would be a double free.
            TethersnapLog.warning(.usb, "no matching notification registered; device watcher unavailable, devices are found by polling only")
            return nil
        }
        TethersnapLog.info(.usb, "device watcher armed for still-image interfaces and \(USBMTPTransport.DeviceID.supported.map(\.name).joined(separator: ", "))")
    }

    deinit {
        invalidate()
        IONotificationPortDestroy(notifyPort)
    }

    /// Stop delivering events and release the IOKit registrations. Synchronizes
    /// with the callback queue so no notification is mid-flight when teardown
    /// proceeds; safe to call more than once (deinit calls it too).
    public func invalidate() {
        queue.sync {
            guard !isInvalidated else { return }
            isInvalidated = true
            IONotificationPortSetDispatchQueue(notifyPort, nil)
            for registration in registrations where registration.iterator != IO_OBJECT_NULL {
                IOObjectRelease(registration.iterator)
            }
            registrations.removeAll()
        }
    }

    /// `matching` is called per registration: each IOServiceAddMatchingNotification
    /// call consumes one dictionary reference.
    private func register(label: String, isArrival: Bool, type: String, matching: () -> Unmanaged<CFMutableDictionary>) {
        let registration = Registration(watcher: self, isArrival: isArrival)
        let refcon = Unmanaged.passUnretained(registration).toOpaque()

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
            guard let watcher = registration.watcher else { return }
            watcher.drain(iterator, registration: registration, notify: true)
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = IOServiceAddMatchingNotification(
            notifyPort, type, matching().takeUnretainedValue(), callback, refcon, &iterator
        )
        guard result == KERN_SUCCESS else {
            TethersnapLog.warning(.usb, "IOServiceAddMatchingNotification(\(type)) for \(label) failed (\(String(format: "0x%08X", result)))")
            return
        }
        registration.iterator = iterator
        registrations.append(registration)
        // Arm the notification by draining the existing matches. Devices already
        // attached surface as arrival events, which is what a fresh app wants.
        drain(iterator, registration: registration, notify: isArrival)
    }

    private func drain(_ iterator: io_iterator_t, registration: Registration, notify: Bool) {
        var events: [Event] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            if registration.isArrival {
                guard let deviceID = USBMTPTransport.deviceID(forService: service), let location = deviceID.locationID else { continue }
                deviceByEntry[entryID] = deviceID
                let isFirst = entriesByLocation[location, default: []].isEmpty
                entriesByLocation[location, default: []].insert(entryID)
                if isFirst { events.append(.attached(deviceID)) }
            } else {
                guard let deviceID = deviceByEntry.removeValue(forKey: entryID), let location = deviceID.locationID else { continue }
                entriesByLocation[location]?.remove(entryID)
                if entriesByLocation[location]?.isEmpty ?? true {
                    entriesByLocation[location] = nil
                    events.append(.removed(deviceID))
                }
            }
        }
        guard notify else { return }
        for event in events {
            switch event {
            case let .attached(deviceID):
                TethersnapLog.notice(.usb, "\(deviceID.name) (\(deviceID.hexPair)) attached")
            case let .removed(deviceID):
                TethersnapLog.notice(.usb, "\(deviceID.name) (\(deviceID.hexPair)) removed")
            }
            handler(event)
        }
    }
}
