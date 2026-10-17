import Foundation

/// Small filesystem probes shared by the kit, the CLI, and the app.
public enum FileSystem {
    /// True when `url` exists and is a directory (symlinks resolved by the
    /// file manager).
    public static func isDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
