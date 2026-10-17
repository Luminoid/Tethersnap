import AppKit
import Foundation
import TethersnapKit

// MARK: - Export

extension AppModel {
    func makeDragPayload(for item: CaptureItem) -> DraggedCapture {
        let dragged = selection.contains(item.id) && selectedItems.count > 1
            ? selectedItems
            : [item]
        return DraggedCapture(items: dragged, service: service, groupedByFolder: viewMode == .byFolder)
    }

    /// ⌘⇧E / File-menu / toolbar primary action: straight to the remembered
    /// folder when it still exists, otherwise the folder panel (the shortcut
    /// must not be dead on first run, nor fail after the drive was ejected).
    func exportCommand() {
        let targets = exportTargets
        guard phase == .ready, !isExporting, !isPickingFolder, !targets.isEmpty else { return }
        runUIAction { model in
            if let folder = model.rememberedExportFolder {
                if await SourceService.existingDirectories(among: [folder]).contains(folder.path) {
                    model.beginExport(targets, to: folder)
                    return
                }
                TethersnapLog.notice(.app, "the remembered export folder is gone; asking for one")
                model.clearRememberedFolder()
            }
            await model.pickExportFolder(for: targets)
        }
    }

    /// "Choose Folder…" and the cell context menu: always ask for a folder.
    func chooseExportFolder(for targets: [CaptureItem]) {
        guard phase == .ready, !isExporting, !isPickingFolder, !targets.isEmpty else { return }
        runUIAction { await $0.pickExportFolder(for: targets) }
    }

    private func pickExportFolder(for targets: [CaptureItem]) async {
        let initial = rememberedExportFolder ?? TethersnapDefaults.exportFolder
        let message = viewMode == .byFolder ? L10n.exportPanelMessageByFolder : L10n.exportPanelMessage
        guard let url = await pickFolder(
            initial: initial, message: message, prompt: L10n.exportPanelPrompt, canCreateDirectories: true
        ) else { return }
        beginExport(targets, to: url)
    }

    func beginExport(_ itemsToExport: [CaptureItem], to directory: URL) {
        guard !isExporting else { return }
        exportTask = Task { [weak self] in
            await self?.export(itemsToExport, to: directory)
        }
    }

    /// The layout follows the view: All Items writes everything into
    /// `directory`, Group by Folder writes one subfolder per source folder.
    func export(_ requested: [CaptureItem], to directory: URL) async {
        // PTP handles are session-scoped: anything the open source no longer
        // lists (an unplug and replug while the folder panel was up) is dropped
        // rather than sent as a stale handle.
        let currentIDs = Set(items.map(\.id))
        let itemsToExport = requested.filter { currentIDs.contains($0.id) }
        if itemsToExport.count < requested.count {
            TethersnapLog.notice(.app, "dropping \(requested.count - itemsToExport.count) items the open source no longer lists")
        }
        guard !itemsToExport.isEmpty, !isExporting else { return }
        let groupedByFolder = viewMode == .byFolder
        let destinations = itemsToExport.exportDestinations(under: directory, groupedByFolder: groupedByFolder)
        TethersnapLog.notice(.app, "exporting \(itemsToExport.count) items\(groupedByFolder ? " into one subfolder per source folder" : "")", private: directory.path)
        exportProgress = ExportProgress(completed: 0, total: itemsToExport.count, currentFraction: 0)
        exportSummary = nil
        let token = CancelToken()
        exportCancelToken = token
        // Unsandboxed app: the folder is a plain path, so there is no
        // security-scoped access to start (it would be a no-op).
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Exporting captures"
        )
        // Chunk callbacks arrive far faster than a progress bar needs; the
        // latest-wins stream coalesces them into one stored consumer task
        // instead of one MainActor task per 512 KB chunk.
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: (Int, Double).self, bufferingPolicy: .bufferingNewest(1)
        )
        exportProgressTask = Task { [weak self] in
            for await (completed, fraction) in progressStream {
                self?.exportProgress?.completed = completed
                self?.exportProgress?.currentFraction = fraction
            }
        }
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            progressContinuation.finish()
            exportProgressTask = nil
            exportProgress = nil
            exportCancelToken = nil
            // Cells refused a thumbnail during the export re-request now.
            thumbnailGeneration += 1
        }

        let usbSource = activeSource.flatMap { $0.kind.isUSB ? $0 : nil }
        do {
            let outcome = try await service.download(destinations, cancelToken: token) { completed, fraction in
                progressContinuation.yield((completed, fraction))
            }
            TethersnapLog.notice(
                .app,
                "export \(outcome.cancelled ? "cancelled" : "finished"): \(outcome.saved) saved, \(outcome.skipped) skipped of \(itemsToExport.count)"
            )
            if outcome.cancelled {
                let summary = ExportSummary(
                    message: L10n.exportCancelled(outcome.saved),
                    folder: outcome.saved > 0 ? directory : nil
                )
                // A cancel mid-file abandons the PTP data phase; reopen for a
                // clean session. A file source has nothing to resync. The
                // reopen clears the summaries, so this one is set after it.
                if let usbSource {
                    await open(usbSource)
                }
                exportSummary = summary
            } else {
                rememberFolder(directory)
                exportSummary = ExportSummary(
                    message: Self.summaryMessage(outcome, folderName: directory.lastPathComponent),
                    folder: directory
                )
            }
        } catch {
            TethersnapLog.error(.app, "export failed", error: error)
            let summary = ExportSummary(message: L10n.exportFailed(error.localizedDescription), folder: nil)
            // A transfer failure mid-object desynchronizes exactly like a
            // cancel; only a clean device response leaves the session usable.
            if let usbSource {
                if case MTPError.deviceResponse = error {} else {
                    await open(usbSource)
                }
            }
            exportSummary = summary
        }
    }

    private static func summaryMessage(_ outcome: SourceService.ExportOutcome, folderName: String) -> String {
        if outcome.skipped == 0 {
            L10n.exportSaved(outcome.saved, folder: folderName)
        } else if outcome.saved == 0 {
            L10n.exportAllExisted(outcome.skipped, folder: folderName)
        } else {
            L10n.exportSavedSkipped(saved: outcome.saved, skipped: outcome.skipped, folder: folderName)
        }
    }

    func cancelExport() {
        TethersnapLog.notice(.app, "export cancel requested")
        exportCancelToken?.cancel()
    }

    func dismissExportSummary() {
        exportSummary = nil
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLastExportInFinder() {
        guard let folder = rememberedExportFolder else { return }
        revealInFinder(folder)
    }

    func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([TethersnapLog.defaultLogFileURL])
    }

    // MARK: - Remembered folder

    /// Settings › Choose Folder…: pick the folder ⌘⇧E exports into.
    func chooseRememberedFolder() {
        guard !isPickingFolder else { return }
        runUIAction { model in
            let initial = model.rememberedExportFolder ?? TethersnapDefaults.exportFolder
            guard let url = await model.pickFolder(
                initial: initial, message: L10n.settingsPanelMessage, prompt: L10n.settingsPanelPrompt, canCreateDirectories: true
            ) else { return }
            model.rememberFolder(url)
        }
    }
}
