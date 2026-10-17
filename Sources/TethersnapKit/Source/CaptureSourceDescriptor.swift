import Foundation

/// Identity and display facts for a source that is attached right now,
/// safe to hand to UI before (and without) opening it.
public struct CaptureSourceDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// A game console in its USB-transfer mode (Nintendo Switch, Switch 2).
        case console
        /// A still camera in PTP/MTP mode.
        case camera
        /// Any other still-image-class USB device (phones, tablets); listed, never auto-opened.
        case ptpDevice
        /// A mounted external volume (USB drive, memory card).
        case volume
        /// A folder the user opened.
        case folder

        /// Backed by the PTP stack (as opposed to the filesystem).
        public var isUSB: Bool {
            switch self {
            case .console, .camera, .ptpDevice: true
            case .volume, .folder: false
            }
        }
    }

    public enum Location: Sendable, Hashable {
        case usb(USBMTPTransport.DeviceID)
        case volume(URL)
        case folder(URL)
    }

    /// Stable across polls while the source stays attached:
    /// `usb:<locationID>:<vid>:<pid>`, `volume:<UUID or path>`, `folder:<path>`.
    public let id: String
    public let name: String
    public let kind: Kind
    /// Secondary line: firmware after a connect, `vvvv:pppp` before, a
    /// volume's layout and path.
    public let detail: String?
    public let location: Location

    public init(id: String, name: String, kind: Kind, detail: String?, location: Location) {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
        self.location = location
    }
}

public extension CaptureSourceDescriptor {
    /// A folder the user opened; the id is its path.
    static func folder(_ url: URL) -> Self {
        let standardized = url.standardizedFileURL
        return Self(
            id: "folder:\(standardized.path)",
            name: standardized.lastPathComponent,
            kind: .folder,
            detail: standardized.path,
            location: .folder(standardized)
        )
    }

    /// A mounted volume; the id is its UUID when the filesystem reports one,
    /// else its mount path.
    static func volume(_ url: URL, name: String, uuid: String?) -> Self {
        Self(
            id: "volume:\(uuid ?? url.path)",
            name: name,
            kind: .volume,
            detail: url.path,
            location: .volume(url)
        )
    }
}

public extension CaptureSourceDescriptor {
    /// What a log message may say in the clear: the kind and model of a USB
    /// device, or only the kind of a drive or folder, whose label or name is
    /// the user's and travels in `logDetail` as the private payload.
    var logName: String {
        kind.isUSB ? "\(kind.rawValue) \(name)" : kind.rawValue
    }

    /// The private payload for a log line about this source: the mount point
    /// or folder path; nil for a USB device.
    var logDetail: String? {
        switch location {
        case .usb: nil
        case let .volume(url), let .folder(url): url.path
        }
    }
}
