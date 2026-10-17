import Foundation

/// Shared display formatting for capture sizes.
public enum CaptureFormat {
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
