/// The release version, shared by the CLI's `--version` and the app's fallback when it
/// runs without a bundle. It must equal `CFBundleShortVersionString` in `Support/Info.plist`
/// (a test enforces this), so bump both together.
public enum TethersnapVersion {
    public static let current = "0.2.0"
}
