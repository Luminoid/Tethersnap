import Foundation

/// Cross-frontend defaults shared by the CLI and the app.
public enum TethersnapDefaults {
    /// Default export destination (`~/Pictures/Switch2`).
    public static var exportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
            .appendingPathComponent("Switch2")
    }
}

/// Shared display formatting for capture sizes.
public enum CaptureFormat {
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
