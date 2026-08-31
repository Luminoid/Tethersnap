import Foundation

/// One screenshot or video capture on the console.
public struct CaptureItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable {
        case screenshot
        case video
    }

    /// PTP object handle, valid for the current session.
    public let handle: UInt32
    public let storageID: UInt32
    public let filename: String
    /// Destination filename for exports; differs from `filename` only when the
    /// library disambiguated a cross-storage collision.
    public var exportFilename: String
    public let kind: Kind
    public let sizeInBytes: Int64
    /// Size of the device-generated thumbnail; 0 when the responder offers none.
    public let thumbSizeInBytes: Int64
    public let date: Date?
    /// Name of the immediate parent folder on the console. The Switch 2 files
    /// captures into one folder per game, so this is the game grouping; nil
    /// when enumeration had no folder context (the flat query path).
    public let folderName: String?

    public var id: UInt32 { handle }

    public init(handle: UInt32, storageID: UInt32, filename: String, kind: Kind,
                sizeInBytes: Int64, thumbSizeInBytes: Int64 = 0, date: Date?, folderName: String? = nil) {
        self.handle = handle
        self.storageID = storageID
        self.filename = filename
        exportFilename = filename
        self.kind = kind
        self.sizeInBytes = sizeInBytes
        self.thumbSizeInBytes = thumbSizeInBytes
        self.date = date
        self.folderName = folderName
    }

    /// Classify a file by extension; nil for anything that is not a capture.
    public static func kind(forFilename filename: String) -> Kind? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png": .screenshot
        case "mp4", "mov": .video
        default: nil
        }
    }
}

public extension [CaptureItem] {
    /// Items of `kind`; nil means everything. Shared by the CLI filter flags
    /// and the app's filter picker.
    func matching(_ kind: CaptureItem.Kind?) -> [CaptureItem] {
        guard let kind else { return self }
        return filter { $0.kind == kind }
    }
}
