import Foundation
import TethersnapKit

/// Typed access to the app's string table.
///
/// SwiftUI's implicit `LocalizedStringKey` lookup targets `Bundle.main`, but an
/// SPM app target's strings live in `Bundle.module`, so every user-visible
/// string goes through here as a plain `String`. Plurals use explicit
/// one/other keys (English's two forms; Chinese repeats one form), avoiding
/// stringsdict machinery that `swift build` handles poorly.
enum L10n {
    // MARK: - States

    static var noSourceTitle: String { localized("nosource.title") }
    static var noSourceMessage: String { localized("nosource.message") }
    static var noSourceHintSwitch: String { localized("nosource.hint_switch") }
    static var noSourceHintCamera: String { localized("nosource.hint_camera") }
    static var noSourceHintDrive: String { localized("nosource.hint_drive") }
    static var failedTitle: String { localized("failed.title") }
    static var retry: String { localized("failed.retry") }
    static var helpCancelOpening: String { localized("help.cancel_opening") }
    static var statusNoSource: String { localized("status.no_source") }
    static var statusFailed: String { localized("status.failed") }
    static var logFileUnavailable: String { localized("status.log_unavailable") }

    static func opening(_ name: String) -> String {
        String(format: localized("source.opening"), name)
    }

    static func statusOpening(_ name: String) -> String {
        String(format: localized("status.opening"), name)
    }

    static func statusConnected(_ name: String, _ detail: String) -> String {
        String(format: localized("status.connected"), name, detail)
    }

    static func statusShowing(_ name: String) -> String {
        String(format: localized("status.showing"), name)
    }

    // MARK: - Sidebar

    static var sidebarDevices: String { localized("sidebar.devices") }
    static var sidebarDrives: String { localized("sidebar.drives") }
    static var sidebarFolders: String { localized("sidebar.folders") }
    static var sidebarEmpty: String { localized("sidebar.empty") }
    static var sidebarRemoveFolder: String { localized("sidebar.remove_folder") }
    static var menuOpenFolder: String { localized("menu.open_folder") }
    static var openFolderPanelMessage: String { localized("openfolder.panel_message") }
    static var openFolderPanelPrompt: String { localized("openfolder.panel_prompt") }

    // MARK: - Filters and sorting

    static var filterLabel: String { localized("filter.label") }
    static var filterAll: String { localized("filter.all") }
    static var filterPhotos: String { localized("filter.photos") }
    static var filterVideos: String { localized("filter.videos") }
    static var helpFilter: String { localized("help.filter") }
    static var sortLabel: String { localized("sort.label") }
    static var sortNewest: String { localized("sort.newest") }
    static var sortOldest: String { localized("sort.oldest") }
    static var sortLargest: String { localized("sort.largest") }
    static var helpSort: String { localized("help.sort") }
    static var viewLabel: String { localized("view.label") }
    static var viewAll: String { localized("view.all") }
    static var viewByFolder: String { localized("view.by_folder") }
    static var helpViewMode: String { localized("help.view_mode") }
    static var groupOther: String { localized("group.other") }

    // MARK: - Toolbar and menus

    static var refresh: String { localized("toolbar.refresh") }
    static var helpRefresh: String { localized("help.refresh") }
    static var menuExport: String { localized("menu.export") }
    static var deselectAll: String { localized("menu.deselect_all") }
    static var cancelExport: String { localized("menu.cancel_export") }
    static var helpCancelExport: String { localized("help.cancel_export") }
    static var showExportFolder: String { localized("menu.show_last_export") }
    static var revealLog: String { localized("menu.reveal_log") }
    static var fixDates: String { localized("menu.fix_dates") }
    static var helpFixDates: String { localized("help.fix_dates") }
    static var cancelFixDates: String { localized("menu.cancel_fix_dates") }
    static var helpCancelFixDates: String { localized("help.cancel_fix_dates") }

    static func exportToFolderMenu(_ name: String) -> String {
        String(format: localized("menu.export_to"), name)
    }

    // MARK: - Empty states

    static var emptyTitle: String { localized("empty.title") }
    static var emptyMessage: String { localized("empty.message") }
    static var emptyFilterTitle: String { localized("empty.filter.title") }
    static var emptyFilterMessage: String { localized("empty.filter.message") }

    // MARK: - Settings and drag

    static var settingsExportFolder: String { localized("settings.export_folder") }
    static var settingsNoFolder: String { localized("settings.no_folder") }
    static var settingsClear: String { localized("settings.clear") }
    static var settingsPanelMessage: String { localized("settings.panel_message") }
    static var settingsPanelPrompt: String { localized("settings.panel_prompt") }
    static var dragFolderName: String { localized("drag.folder_name") }

    // MARK: - Cells and preview

    /// "Photo", "Video", or "RAW" for a camera RAW frame.
    static func kindName(_ item: CaptureItem) -> String {
        if item.isRawImage { return localized("kind.raw") }
        return localized(item.kind == .video ? "kind.video" : "kind.photo")
    }

    static var preview: String { localized("preview.title") }
    static var previewVideoHint: String { localized("preview.video_hint") }
    static var showItemInFinder: String { localized("cell.show_in_finder") }
    static var close: String { localized("common.close") }
    static var cancel: String { localized("common.cancel") }

    // MARK: - Export

    static var exportAll: String { localized("export.all") }

    static func exportCount(_ count: Int) -> String {
        String.localizedStringWithFormat(localized("export.count"), count)
    }

    static func exportToFolder(_ name: String) -> String {
        String(format: localized("export.to_folder"), name)
    }

    static var chooseFolder: String { localized("export.choose_folder") }
    static var helpExport: String { localized("help.export") }
    static var exportPanelMessage: String { localized("export.panel_message") }
    static var exportPanelMessageByFolder: String { localized("export.panel_message_by_folder") }
    static var exportPanelPrompt: String { localized("export.panel_prompt") }

    static func helpExportRemembered(_ name: String) -> String {
        String(format: localized("help.export_remembered"), name)
    }

    static func exportProgress(_ current: Int, _ total: Int) -> String {
        String.localizedStringWithFormat(localized("export.progress"), current, total)
    }

    static var showInFinder: String { localized("export.show_in_finder") }

    static func exportSaved(_ count: Int, folder: String) -> String {
        String.localizedStringWithFormat(localized(count == 1 ? "export.saved.one" : "export.saved.other"), count, folder)
    }

    static func exportSavedSkipped(saved: Int, skipped: Int, folder: String) -> String {
        String.localizedStringWithFormat(localized("export.saved_skipped"), saved, folder, skipped)
    }

    static func exportAllExisted(_ count: Int, folder: String) -> String {
        String.localizedStringWithFormat(localized("export.all_existed"), count, folder)
    }

    static func exportCancelled(_ saved: Int) -> String {
        String.localizedStringWithFormat(localized("export.cancelled"), saved)
    }

    static func exportFailed(_ reason: String) -> String {
        String(format: localized("export.failed"), reason)
    }

    // MARK: - Fix dates from filenames

    static var dateFixTitle: String { localized("datefix.title") }
    static var dateFixExplainer: String { localized("datefix.explainer") }
    static var dateFixFolder: String { localized("datefix.folder") }
    static var dateFixChangeFolder: String { localized("datefix.change_folder") }
    static var dateFixIncludeSubfolders: String { localized("datefix.include_subfolders") }
    static var dateFixOverwrite: String { localized("datefix.overwrite") }
    static var dateFixOverwriteHint: String { localized("datefix.overwrite_hint") }
    static var dateFixRun: String { localized("datefix.run") }
    static var dateFixPanelMessage: String { localized("datefix.panel_message") }
    static var dateFixPanelPrompt: String { localized("datefix.panel_prompt") }
    static var dateFixPreparing: String { localized("datefix.preparing") }

    static func dateFixProgress(_ current: Int, _ total: Int) -> String {
        String.localizedStringWithFormat(localized("datefix.progress"), current, total)
    }

    static func dateFixSummary(_ updated: Int, of total: Int, folder: String) -> String {
        String.localizedStringWithFormat(localized("datefix.summary"), updated, total, folder)
    }

    static func dateFixSummaryDetail(alreadyDated: Int, noDate: Int, failed: Int) -> String {
        String.localizedStringWithFormat(localized("datefix.summary_detail"), alreadyDated, noDate, failed)
    }

    static func dateFixSummaryNone(_ folder: String) -> String {
        String(format: localized("datefix.summary_none"), folder)
    }

    static func dateFixCancelled(_ updated: Int) -> String {
        String.localizedStringWithFormat(localized("datefix.cancelled"), updated)
    }

    static func dateFixFailed(_ reason: String) -> String {
        String(format: localized("datefix.failed"), reason)
    }

    static func dateFixFailedFiles(_ names: String) -> String {
        String(format: localized("datefix.failed_files"), names)
    }

    // MARK: - Counts

    static func capturesCount(_ count: Int) -> String {
        String.localizedStringWithFormat(localized(count == 1 ? "captures.count.one" : "captures.count.other"), count)
    }

    private static func localized(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
