import Foundation
import TethersnapKit

// MARK: - Fix dates from filenames

extension AppModel {
    /// ⌘⇧D / toolbar: pick the folder (preset to the export folder), then
    /// show the options sheet.
    func chooseDateFixFolder() {
        guard !isFixingDates, !isPickingFolder else { return }
        runUIAction { model in
            let initial = model.dateFixFolder ?? model.rememberedExportFolder ?? TethersnapDefaults.exportFolder
            guard let url = await model.pickFolder(initial: initial, message: L10n.dateFixPanelMessage, prompt: L10n.dateFixPanelPrompt) else { return }
            model.dateFixFolder = url
            model.dateFixSheetPresented = true
        }
    }

    func beginDateFix(options: CaptureDateFixer.Options) {
        guard let folder = dateFixFolder, !isFixingDates else { return }
        dateFixTask = Task { [weak self] in
            await self?.fixDates(in: folder, options: options)
        }
    }

    func fixDates(in folder: URL, options: CaptureDateFixer.Options) async {
        guard !isFixingDates else { return }
        TethersnapLog.notice(.app, "fixing dates (overwrite \(options.overwrite), recursive \(options.recursive))", private: folder.path)
        dateFixProgress = DateFixProgress(completed: 0, total: 0)
        dateFixSummary = nil
        let token = CancelToken()
        dateFixCancelToken = token
        // Unsandboxed app: plain path, no security-scoped access to start.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Fixing capture dates"
        )
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: (Int, Int).self, bufferingPolicy: .bufferingNewest(1)
        )
        dateFixProgressTask = Task { [weak self] in
            for await (completed, total) in progressStream {
                self?.dateFixProgress = DateFixProgress(completed: completed, total: total)
            }
        }
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            progressContinuation.finish()
            dateFixProgressTask = nil
            dateFixProgress = nil
            dateFixCancelToken = nil
        }

        let report = await CaptureDateFixer(options: options).fix(folder: folder, cancelToken: token) { completed, total in
            progressContinuation.yield((completed, total))
        }
        let updated = report.updated.count
        let failed = report.failed
        TethersnapLog.notice(.app, "date fix \(report.cancelled ? "cancelled" : "finished"): \(updated) updated, \(failed.count) failed of \(report.entries.count)")
        let folderName = folder.lastPathComponent
        let message: String
        var detail: String?
        if report.cancelled {
            message = L10n.dateFixCancelled(updated)
        } else if report.entries.count == 1, let (url, error) = failed.first, url == folder {
            // The folder itself could not be listed.
            message = L10n.dateFixFailed(error.localizedDescription)
        } else if updated == 0, failed.isEmpty {
            message = L10n.dateFixSummaryNone(folderName)
        } else {
            let counts = L10n.dateFixSummaryDetail(
                alreadyDated: report.alreadyDated.count, noDate: report.noDateInName.count, failed: failed.count
            )
            message = "\(L10n.dateFixSummary(updated, of: report.entries.count, folder: folderName)) · \(counts)"
            if !failed.isEmpty {
                // The chip's tooltip names the files; the line itself only counts them.
                detail = L10n.dateFixFailedFiles(failed.map(\.0.lastPathComponent).joined(separator: ", "))
            }
        }
        dateFixSummary = ExportSummary(message: message, folder: folder, detail: detail)
    }

    func cancelDateFix() {
        TethersnapLog.notice(.app, "date fix cancel requested")
        dateFixCancelToken?.cancel()
    }

    func dismissDateFixSummary() {
        dateFixSummary = nil
    }
}
