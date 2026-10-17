import AppKit
import Foundation

/// `NSOpenPanel` as a folder chooser, awaited from the main actor. SwiftUI's
/// `fileImporter` cannot start in a given directory or carry a message and
/// prompt, which every folder flow here wants (exports open on the remembered
/// folder, the date fix on the export folder).
@MainActor
enum FolderPicker {
    /// nil when the user cancels. Runs as a sheet on the key window when there
    /// is one, else as a standalone panel; never `runModal`, which nests a
    /// modal loop under SwiftUI. `canCreateDirectories` is for destinations
    /// (an export folder may not exist yet); sources are chosen as they are.
    static func choose(initial: URL?, message: String, prompt: String, canCreateDirectories: Bool = false) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreateDirectories
        panel.directoryURL = initial
        panel.message = message
        panel.prompt = prompt
        return await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }
}
