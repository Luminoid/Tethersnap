import Foundation

/// Cross-frontend defaults shared by the CLI and the app.
public enum TethersnapDefaults {
    /// Default export destination (`~/Pictures/Tethersnap`).
    public static var exportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
            .appendingPathComponent("Tethersnap")
    }
}
