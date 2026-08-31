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

    static var waitingTitle: String { localized("waiting.title") }
    static var connecting: String { localized("waiting.connecting") }
    static var waitingStep1: String { localized("waiting.step1") }
    static var waitingStep2: String { localized("waiting.step2") }
    static var waitingStep3: String { localized("waiting.step3") }
    static var failedTitle: String { localized("failed.title") }
    static var retry: String { localized("failed.retry") }

    // MARK: - Filters and sorting

    static var filterLabel: String { localized("filter.label") }
    static var filterAll: String { localized("filter.all") }
    static var filterScreenshots: String { localized("filter.screenshots") }
    static var filterVideos: String { localized("filter.videos") }
    static var sortLabel: String { localized("sort.label") }
    static var sortNewest: String { localized("sort.newest") }
    static var sortOldest: String { localized("sort.oldest") }
    static var sortLargest: String { localized("sort.largest") }
    static var helpSort: String { localized("help.sort") }
    static var viewLabel: String { localized("view.label") }
    static var viewAll: String { localized("view.all") }
    static var viewByGame: String { localized("view.by_game") }
    static var groupOther: String { localized("group.other") }

    // MARK: - Toolbar and menus

    static var refresh: String { localized("toolbar.refresh") }
    static var helpRefresh: String { localized("help.refresh") }
    static var menuExport: String { localized("menu.export") }
    static var selectAll: String { localized("menu.select_all") }
    static var deselectAll: String { localized("menu.deselect_all") }
    static var cancelExport: String { localized("menu.cancel_export") }
    static var showExportFolder: String { localized("menu.show_last_export") }
    static var revealLog: String { localized("menu.reveal_log") }

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
    static var dragFolderName: String { localized("drag.folder_name") }

    // MARK: - Cells and preview

    static func kindName(_ kind: CaptureItem.Kind) -> String {
        localized(kind == .video ? "kind.video" : "kind.screenshot")
    }

    static var preview: String { localized("preview.title") }
    static var previewVideoHint: String { localized("preview.video_hint") }
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

    // MARK: - Counts

    static func capturesCount(_ count: Int) -> String {
        String.localizedStringWithFormat(localized(count == 1 ? "captures.count.one" : "captures.count.other"), count)
    }

    private static func localized(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
