import AppKit
import SwiftUI

@main
struct TethersnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // When run as a bare SPM executable (swift run TethersnapApp) there is no
        // bundle to mark us as a regular app; do it explicitly so the window
        // fronts and gets a menu bar. Harmless inside a real .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // A single window by design: previews and selection are shared app
        // state, so extra windows would mirror one another (one device, one window).
        Window("Tethersnap", id: "main") {
            ContentView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model
                    NSApp.activate()
                }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.refresh) {
                    model.beginRefresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.phase != .connected)

                exportMenuItem

                Button(L10n.cancelExport) {
                    model.cancelExport()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isExporting)

                Button(L10n.showExportFolder) {
                    model.revealLastExportInFinder()
                }
                .disabled(model.rememberedExportFolder == nil)
            }
            CommandGroup(after: .help) {
                Button(L10n.revealLog) {
                    model.revealLogInFinder()
                }
            }
            // After, not replacing: replacing .pasteboard would delete Cut /
            // Copy / Paste / Delete from the Edit menu.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L10n.selectAll) {
                    model.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(model.phase != .connected)

                Button(L10n.deselectAll) {
                    model.clearSelection()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    @ViewBuilder
    private var exportMenuItem: some View {
        if let remembered = model.rememberedExportFolder {
            // No ellipsis: exports straight to the remembered folder.
            Button(L10n.exportToFolderMenu(remembered.lastPathComponent)) {
                model.exportCommand()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.phase != .connected || model.isExporting || model.exportTargets.isEmpty)
        } else {
            // Ellipsis is honest here: with no remembered folder the command
            // opens the folder picker, so ⌘⇧E works on first run too.
            Button(L10n.menuExport) {
                model.exportCommand()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.phase != .connected || model.isExporting || model.exportTargets.isEmpty)
        }
    }
}

/// Sends a best-effort CloseSession and releases the USB claim before the
/// process exits. Deliberately NOT `.terminateLater` + an async reply: quit
/// must never wait on the device actor, whose thread can be stuck inside a
/// blocking USB call (a descriptor-walk hang once left the app un-quittable
/// forever). A short bounded wait, then terminate regardless; process exit
/// releases the kernel claim either way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var didCleanUp = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !didCleanUp else { return .terminateNow }
        didCleanUp = true
        let service = model.beginTerminationCleanup()
        let semaphore = DispatchSemaphore(value: 0)
        // One-shot fire-and-forget is correct here: the process is exiting.
        Task.detached(priority: .userInitiated) {
            await service.disconnect()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return .terminateNow
    }
}
