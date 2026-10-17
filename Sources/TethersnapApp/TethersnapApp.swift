import AppKit
import SwiftUI
import TethersnapKit

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
        // state, so extra windows would mirror one another (one open source,
        // one window).
        Window("Tethersnap", id: "main") {
            ContentView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model
                    NSApp.activate()
                }
        }
        .defaultSize(Layout.windowDefaultSize)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button(L10n.menuOpenFolder) {
                    model.openFolderCommand()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isExporting || model.isPickingFolder)

                Button(L10n.refresh) {
                    model.beginRefresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.phase != .ready || model.isExporting)

                exportMenuItem

                Button(L10n.fixDates) {
                    model.chooseDateFixFolder()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.isFixingDates || model.isPickingFolder)

                Button(L10n.cancelExport) {
                    model.cancelExport()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isExporting)

                // ⌘⌥. so a date fix running beside an export has its own stop;
                // the progress chips' tooltips name both shortcuts.
                Button(L10n.cancelFixDates) {
                    model.cancelDateFix()
                }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!model.isFixingDates)

                Button(L10n.showExportFolder) {
                    model.revealLastExportInFinder()
                }
                .disabled(model.rememberedExportFolder == nil)
            }
            CommandGroup(after: .help) {
                Button(L10n.revealLog) {
                    model.revealLogInFinder()
                }
                .disabled(model.logFileFailure != nil)
            }
            // After, not replacing: replacing .pasteboard would delete Cut /
            // Copy / Paste / Delete from the Edit menu. Select All (⌘A) is the
            // system item in that group; the grid answers it via `onCommand`.
            CommandGroup(after: .pasteboard) {
                Button(L10n.deselectAll) {
                    model.clearSelection()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Picker(L10n.filterLabel, selection: Bindable(model).filter) {
                    ForEach(AppModel.Filter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .disabled(model.phase != .ready)

                Picker(L10n.viewLabel, selection: Bindable(model).viewMode) {
                    ForEach(AppModel.ViewMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(model.phase != .ready)

                Picker(L10n.sortLabel, selection: Bindable(model).sortOrder) {
                    ForEach(AppModel.SortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .disabled(model.phase != .ready)

                Divider()
                Button(L10n.preview) {
                    model.previewSelected()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.phase != .ready || model.selectionAnchor == nil)
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
            .disabled(model.phase != .ready || model.isExporting || model.isPickingFolder || model.exportTargets.isEmpty)
        } else {
            // Ellipsis is honest here: with no remembered folder the command
            // opens the folder picker, so ⌘⇧E works on first run too.
            Button(L10n.menuExport) {
                model.exportCommand()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.phase != .ready || model.isExporting || model.isPickingFolder || model.exportTargets.isEmpty)
        }
    }
}

/// Sends a best-effort CloseSession and releases the USB claim before the
/// process exits. Deliberately NOT `.terminateLater` + an async reply: quit
/// must never wait on the source actor, whose thread can be stuck inside a
/// blocking USB call (a descriptor-walk hang once left the app un-quittable
/// forever). A short bounded wait, then terminate regardless; process exit
/// releases the kernel claim either way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var didCleanUp = false

    /// One window, and it holds the console or camera claim: with it closed
    /// there is no UI left to release the device, so closing quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !didCleanUp else { return .terminateNow }
        didCleanUp = true
        let service = model.beginTerminationCleanup()
        let semaphore = DispatchSemaphore(value: 0)
        // One-shot fire-and-forget is correct here: the process is exiting.
        Task.detached(priority: .userInitiated) {
            // Drag folders Finder is done with go first: a temp-dir listing,
            // never a wait on the source.
            SourceService.reapDragTemporaries(olderThan: 300)
            await service.close()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            TethersnapLog.warning(.app, "closing the source did not finish within 2 s of quit; exiting anyway (process exit releases the USB claim)")
        }
        return .terminateNow
    }
}
