import Foundation

/// Discovery and opening of capture sources, shared by the CLI and the app.
public enum CaptureSources {
    /// Attached USB devices (consoles first) followed by mounted external volumes.
    public static func attached() -> [CaptureSourceDescriptor] {
        attachedUSB() + attachedVolumes()
    }

    private static func attachedUSB() -> [CaptureSourceDescriptor] {
        USBMTPTransport.attachedDevices().map(\.descriptor)
    }

    private static func attachedVolumes() -> [CaptureSourceDescriptor] {
        VolumeWatcher.mountedVolumes()
    }

    /// Open a source: a USB device goes through the full connect ladder, a
    /// volume or folder through a layout detection.
    public static func open(_ descriptor: CaptureSourceDescriptor) throws -> any CaptureSource {
        switch descriptor.location {
        case let .usb(deviceID):
            try TethersnapConnection.connect(to: deviceID)
        case let .volume(url), let .folder(url):
            try VolumeCaptureSource(root: url, descriptor: descriptor)
        }
    }

    /// Open a folder the user chose.
    public static func openFolder(_ url: URL) throws -> any CaptureSource {
        try VolumeCaptureSource(root: url, descriptor: .folder(url))
    }
}
