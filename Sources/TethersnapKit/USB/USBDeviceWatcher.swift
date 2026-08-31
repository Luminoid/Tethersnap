import Foundation
import IOKit
import IOUSBHost

/// Push notifications for console arrival/removal via IOKit matching
/// notifications, so the app reacts immediately instead of only on a poll.
///
/// Events are delivered on an internal serial queue; the handler must be
/// `@Sendable` and hop to wherever it needs to go.
public final class USBDeviceWatcher: @unchecked Sendable {
    public enum Event: Sendable {
        case attached(USBMTPTransport.DeviceID)
        case removed(USBMTPTransport.DeviceID)
    }

    private final class Registration {
        unowned let watcher: USBDeviceWatcher
        let deviceID: USBMTPTransport.DeviceID
        let isArrival: Bool
        var iterator: io_iterator_t = IO_OBJECT_NULL

        init(watcher: USBDeviceWatcher, deviceID: USBMTPTransport.DeviceID, isArrival: Bool) {
            self.watcher = watcher
            self.deviceID = deviceID
            self.isArrival = isArrival
        }
    }

    private let queue = DispatchQueue(label: "dev.luminoid.Tethersnap.USBDeviceWatcher")
    private let handler: @Sendable (Event) -> Void
    private let notifyPort: IONotificationPortRef
    private var registrations: [Registration] = []
    private var isInvalidated = false
    /// Start watching every supported console ID.
    public init?(handler: @escaping @Sendable (Event) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.handler = handler
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        for deviceID in USBMTPTransport.DeviceID.supported {
            register(deviceID: deviceID, isArrival: true, type: kIOFirstMatchNotification)
            register(deviceID: deviceID, isArrival: false, type: kIOTerminatedNotification)
        }
        guard !registrations.isEmpty else {
            IONotificationPortDestroy(port)
            return nil
        }
        TethersnapLog.info(TethersnapLog.usb, "device watcher armed for \(USBMTPTransport.DeviceID.supported.map(\.name).joined(separator: ", "))")
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

    private func register(deviceID: USBMTPTransport.DeviceID, isArrival: Bool, type: String) {
        // Each IOServiceAddMatchingNotification call consumes one dictionary reference.
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
        let registration = Registration(watcher: self, deviceID: deviceID, isArrival: isArrival)
        let refcon = Unmanaged.passUnretained(registration).toOpaque()

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
            registration.watcher.drain(iterator, registration: registration, notify: true)
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = IOServiceAddMatchingNotification(
            notifyPort, type, matching.takeUnretainedValue(), callback, refcon, &iterator
        )
        guard result == KERN_SUCCESS else {
            TethersnapLog.error(TethersnapLog.usb, "IOServiceAddMatchingNotification(\(type)) failed: \(result)")
            return
        }
        registration.iterator = iterator
        registrations.append(registration)
        // Arm the notification by draining the existing matches. Devices already
        // attached surface as arrival events, which is what a fresh app wants.
        drain(iterator, registration: registration, notify: isArrival)
    }

    private func drain(_ iterator: io_iterator_t, registration: Registration, notify: Bool) {
        var matched = false
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            matched = true
            IOObjectRelease(service)
        }
        guard matched, notify else { return }
        let event: Event = registration.isArrival ? .attached(registration.deviceID) : .removed(registration.deviceID)
        TethersnapLog.info(TethersnapLog.usb, "\(registration.deviceID.name) \(registration.isArrival ? "attached" : "removed")")
        handler(event)
    }
}
