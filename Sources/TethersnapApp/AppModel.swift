import AppKit
import Foundation
import Observation
import TethersnapKit

/// UI state machine: waiting for a console → connected grid → export progress.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case waiting
        case connecting
        case connected
        case failed(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case screenshots
        case videos

        var id: String { rawValue }

        var kind: CaptureItem.Kind? {
            switch self {
            case .all: nil
            case .screenshots: .screenshot
            case .videos: .video
            }
        }

        var displayName: String {
            switch self {
            case .all: L10n.filterAll
            case .screenshots: L10n.filterScreenshots
            case .videos: L10n.filterVideos
            }
        }
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        /// One flat grid of everything.
        case all
        /// Sections per console folder (the Switch 2 keeps one folder per game).
        case byGame

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: L10n.viewAll
            case .byGame: L10n.viewByGame
            }
        }

        var symbolName: String {
            switch self {
            case .all: "square.grid.2x2"
            case .byGame: "folder"
            }
        }
    }

    /// One by-game section: the console folder name and its visible items.
    struct FolderGroup: Identifiable, Equatable {
        let name: String
        let items: [CaptureItem]
        var id: String { name }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newestFirst
        case oldestFirst
        case largestFirst

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .newestFirst: L10n.sortNewest
            case .oldestFirst: L10n.sortOldest
            case .largestFirst: L10n.sortLargest
            }
        }

        func sorted(_ items: [CaptureItem]) -> [CaptureItem] {
            switch self {
            case .newestFirst: items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            case .oldestFirst: items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            case .largestFirst: items.sorted { $0.sizeInBytes > $1.sizeInBytes }
            }
        }
    }

    struct ExportProgress: Equatable {
        var completed: Int
        var total: Int
        var currentFraction: Double

        var overallFraction: Double {
            guard total > 0 else { return 0 }
            return min(1, (Double(completed) + currentFraction) / Double(total))
        }
    }

    struct ExportSummary: Equatable {
        let message: String
        let folder: URL?
    }

    private(set) var phase: Phase = .waiting
    private(set) var deviceName = ""
    private(set) var firmwareVersion = ""
    private(set) var exportProgress: ExportProgress?
    private(set) var exportSummary: ExportSummary?
    /// Everything on the console; `filteredItems` is the visible slice.
    private(set) var items: [CaptureItem] = [] { didSet { updateFilteredItems() } }
    /// Memoized filter+sort result; recomputing per body access re-sorted the
    /// whole library several times per render. In by-game mode this is the
    /// concatenation of `groupedItems`, so linear things (keyboard navigation,
    /// shift-click ranges, Export All) always follow the visual order.
    private(set) var filteredItems: [CaptureItem] = []
    /// Sections for by-game mode, ordered by each folder's first item in the
    /// current sort; empty in flat mode.
    private(set) var groupedItems: [FolderGroup] = []
    /// Bumped when a blocked thumbnail context ends (an export finishes) so
    /// visible cells re-request thumbnails they were refused.
    private(set) var thumbnailGeneration = 0
    /// Last folder an export landed in, if it still exists. Cached: resolving
    /// it hits UserDefaults and the filesystem, which must not run per render.
    private(set) var rememberedExportFolder: URL?
    var filter: Filter = .all { didSet { updateFilteredItems() } }
    var sortOrder: SortOrder = .newestFirst { didSet { updateFilteredItems() } }
    var viewMode: ViewMode = AppModel.loadViewMode() {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
            updateFilteredItems()
        }
    }

    var selection: Set<UInt32> = []
    var previewItem: CaptureItem?
    var exportPickerPresented = false
    var pendingExportItems: [CaptureItem] = []

    private let service = DeviceService()
    private var thumbnailCache: [UInt32: NSImage] = [:]
    private var thumbnailCacheOrder: [UInt32] = []
    private var lastPreview: (handle: UInt32, image: NSImage)?
    private var selectionAnchor: UInt32?
    private var pollTask: Task<Void, Never>?
    private var usbEventTask: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportProgressTask: Task<Void, Never>?
    private var uiActionTask: Task<Void, Never>?
    private var watcher: USBDeviceWatcher?
    private var exportCancelToken: CancelToken?

    private static let lastExportFolderKey = "lastExportFolderPath"
    private static let viewModeKey = "viewMode"

    private static func loadViewMode() -> ViewMode {
        UserDefaults.standard.string(forKey: viewModeKey).flatMap(ViewMode.init(rawValue:)) ?? .all
    }

    var selectedItems: [CaptureItem] {
        filteredItems.filter { selection.contains($0.handle) }
    }

    /// Items the export actions target: the selection when there is one,
    /// otherwise everything visible.
    var exportTargets: [CaptureItem] {
        selection.isEmpty ? filteredItems : selectedItems
    }

    var totalSizeLabel: String {
        CaptureFormat.size(filteredItems.reduce(0) { $0 + $1.sizeInBytes })
    }

    var isExporting: Bool { exportProgress != nil }

    /// One-line connection status for the persistent status chip.
    var statusLabel: String {
        switch phase {
        case .waiting: L10n.statusWaiting
        case .connecting: L10n.connecting
        case .connected: L10n.statusConnected(deviceName, firmwareVersion)
        case .failed: L10n.statusFailed
        }
    }

    private func updateFilteredItems() {
        let visible = sortOrder.sorted(items.matching(filter.kind))
        if viewMode == .byGame {
            // Buckets keyed by folder name, ordered by first appearance in the
            // sorted list, so sections follow the active sort.
            var order: [String] = []
            var buckets: [String: [CaptureItem]] = [:]
            for item in visible {
                let name = item.folderName ?? L10n.groupOther
                if buckets[name] == nil { order.append(name) }
                buckets[name, default: []].append(item)
            }
            groupedItems = order.map { FolderGroup(name: $0, items: buckets[$0] ?? []) }
            filteredItems = groupedItems.flatMap(\.items)
        } else {
            groupedItems = []
            filteredItems = visible
        }
        // A selection must never target something the visible list (and the
        // "Export N" label) doesn't show.
        selection.formIntersection(filteredItems.map(\.handle))
    }

    // MARK: - Device lifecycle

    /// IOKit notifications drive arrival/removal; a slow poll stays as a
    /// safety net in case a notification is missed.
    func start() {
        guard pollTask == nil else { return }
        // Every run leaves a full debug trace on disk (previous run kept), so
        // bug reports never depend on having had `log stream` running.
        if let logURL = TethersnapLog.enableFileLogging() {
            TethersnapLog.info(TethersnapLog.app, "file log at \(logURL.path)")
        }
        TethersnapLog.info(TethersnapLog.app, "app started, watching for consoles")
        rememberedExportFolder = Self.loadRememberedFolder()
        // Startup housekeeping off main: reap stale drag folders, then build
        // the watcher (IOKit registration IPC). The bridging Task inside the
        // handler only hops to the main actor, where the real work runs in
        // the stored, cancel-and-replace `usbEventTask`.
        housekeepingTask = Task.detached(priority: .utility) { [weak self] in
            DeviceService.reapDragTemporaries()
            // Strong rebind only for the duration of this short-lived task;
            // the watcher handler itself captures weakly.
            guard let self else { return }
            let watcher = USBDeviceWatcher { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.enqueueUSBEvent(event)
                }
            }
            await adopt(watcher: watcher)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Cancel background work and release the device watcher (paired with
    /// `start()`; the app calls it on termination).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        usbEventTask?.cancel()
        usbEventTask = nil
        housekeepingTask?.cancel()
        housekeepingTask = nil
        uiActionTask?.cancel()
        uiActionTask = nil
        watcher?.invalidate()
        watcher = nil
    }

    /// Synchronous main-actor part of app termination: cancel everything and
    /// hand the service back so the delegate can attempt a *bounded*,
    /// off-main CloseSession. Termination must never await this actor's
    /// availability: a wedged USB call would hold quit hostage (bit us).
    func beginTerminationCleanup() -> DeviceService {
        exportCancelToken?.cancel()
        exportTask?.cancel()
        stop()
        return service
    }

    private func adopt(watcher: USBDeviceWatcher?) {
        guard pollTask != nil else {
            watcher?.invalidate()
            return
        }
        self.watcher = watcher
    }

    private func enqueueUSBEvent(_ event: USBDeviceWatcher.Event) {
        usbEventTask?.cancel()
        usbEventTask = Task { [weak self] in
            await self?.handleUSBEvent(event)
        }
    }

    private func handleUSBEvent(_ event: USBDeviceWatcher.Event) async {
        switch event {
        case let .attached(deviceID):
            TethersnapLog.info(TethersnapLog.app, "\(deviceID.name) arrival notification")
            // A fresh enumeration (replug, or the stale-session USB reset)
            // supersedes an old failure; give the new attach a clean try.
            if case .failed = phase {
                phase = .waiting
            }
            await pollOnce()
        case let .removed(deviceID):
            TethersnapLog.info(TethersnapLog.app, "\(deviceID.name) removal notification")
            // Nothing to tear down while waiting; the console may just be
            // re-enumerating (mode switches), so otherwise trust the registry.
            guard phase != .waiting else { return }
            await pollOnce()
        }
    }

    private func pollOnce() async {
        let attached = await service.attachedDeviceName() != nil
        switch phase {
        case .waiting where attached:
            await connect()
        case .connected where !attached, .connecting where !attached:
            await disconnectToWaiting()
        default:
            break
        }
    }

    func connect() async {
        phase = .connecting
        do {
            let device = try await service.connect()
            deviceName = device.name
            firmwareVersion = device.firmwareVersion
            items = device.items
            clearThumbnailCache()
            selection = []
            phase = .connected
            TethersnapLog.info(TethersnapLog.app, "connected: \(device.name), \(device.items.count) captures")
        } catch {
            await service.disconnect()
            TethersnapLog.error(TethersnapLog.app, "connect failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        phase = .waiting
        await pollOnce()
    }

    func beginRefresh() {
        uiActionTask?.cancel()
        uiActionTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func beginRetry() {
        uiActionTask?.cancel()
        uiActionTask = Task { [weak self] in
            await self?.retry()
        }
    }

    func refresh() async {
        guard phase == .connected else { return }
        do {
            items = try await service.reloadItems()
        } catch {
            // Losing the grid silently looks like a wipe; explain and offer Retry.
            TethersnapLog.error(TethersnapLog.app, "refresh failed: \(error.localizedDescription)")
            await service.disconnect()
            phase = .failed(error.localizedDescription)
        }
    }

    private func disconnectToWaiting() async {
        await service.disconnect()
        items = []
        clearThumbnailCache()
        selection = []
        deviceName = ""
        firmwareVersion = ""
        previewItem = nil
        exportSummary = nil
        phase = .waiting
        TethersnapLog.info(TethersnapLog.app, "back to waiting")
    }

    /// Reconnect when a swallowed-looking failure actually killed the session
    /// (a desynchronized session cannot be resumed, only rebuilt).
    private func recoverIfSessionDied() async {
        guard phase == .connected else { return }
        if await !service.isSessionValid() {
            TethersnapLog.error(TethersnapLog.app, "session invalidated; reconnecting")
            await connect()
        }
    }

    // MARK: - Selection

    func select(_ item: CaptureItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let anchorIndex = filteredItems.firstIndex(where: { $0.handle == anchor }),
           let itemIndex = filteredItems.firstIndex(where: { $0.handle == item.handle }) {
            let range = min(anchorIndex, itemIndex) ... max(anchorIndex, itemIndex)
            selection = Set(filteredItems[range].map(\.handle))
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(item.handle) {
                selection.remove(item.handle)
            } else {
                selection.insert(item.handle)
            }
        } else {
            selection = [item.handle]
        }
        selectionAnchor = item.handle
    }

    func selectAll() {
        selection = Set(filteredItems.map(\.handle))
    }

    func clearSelection() {
        selection = []
    }

    /// Arrow-key navigation: move a single selection through the visible order.
    func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        let currentIndex = selectionAnchor.flatMap { anchor in
            filteredItems.firstIndex { $0.handle == anchor }
        }
        let newIndex = currentIndex.map { max(0, min(filteredItems.count - 1, $0 + offset)) } ?? 0
        let item = filteredItems[newIndex]
        selection = [item.handle]
        selectionAnchor = item.handle
    }

    /// Open the preview for the current selection anchor (Space/Return).
    func previewSelected() {
        guard let anchor = selectionAnchor,
              let item = filteredItems.first(where: { $0.handle == anchor }) else { return }
        previewItem = item
    }

    // MARK: - Thumbnails

    func thumbnail(for item: CaptureItem) async -> NSImage? {
        if let cached = thumbnailCache[item.handle] { return cached }
        guard phase == .connected, !isExporting else { return nil }
        do {
            guard let payload = try await service.thumbnailPayload(for: item) else { return nil }
            if let image = await Thumbnailer.downsample(payload.data, maxPixel: 480) {
                cacheThumbnail(image, for: item.handle)
                return image
            }
            // A bounded prefix that didn't decode; fetch the whole image once.
            if !payload.isComplete {
                let full = try await service.fullImageData(for: item)
                if let image = await Thumbnailer.downsample(full, maxPixel: 480) {
                    cacheThumbnail(image, for: item.handle)
                    return image
                }
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            TethersnapLog.error(TethersnapLog.app, "thumbnail for \(item.filename) failed: \(error.localizedDescription)")
            await recoverIfSessionDied()
            return nil
        }
    }

    /// Full-resolution image for the preview sheet (screenshots only). Throws
    /// so the sheet can show the failure instead of spinning forever.
    func fullImage(for item: CaptureItem) async throws -> NSImage {
        if let lastPreview, lastPreview.handle == item.handle { return lastPreview.image }
        guard item.kind == .screenshot, phase == .connected else { throw MTPError.deviceNotFound }
        do {
            let data = try await service.fullImageData(for: item)
            // Downsample off-main to display scale; a raw NSImage(data:) would
            // decode the full 4K JPEG on the main thread at draw time.
            guard let image = await Thumbnailer.downsample(data, maxPixel: 2560) else {
                throw MTPError.malformedData("preview image failed to decode")
            }
            lastPreview = (item.handle, image)
            return image
        } catch {
            TethersnapLog.error(TethersnapLog.app, "preview for \(item.filename) failed: \(error.localizedDescription)")
            await recoverIfSessionDied()
            throw error
        }
    }

    private func cacheThumbnail(_ image: NSImage, for handle: UInt32) {
        if thumbnailCache[handle] == nil {
            thumbnailCacheOrder.append(handle)
        }
        thumbnailCache[handle] = image
        // Simple FIFO bound; evicted thumbnails are re-fetchable from the console.
        while thumbnailCacheOrder.count > 300 {
            thumbnailCache.removeValue(forKey: thumbnailCacheOrder.removeFirst())
        }
    }

    private func clearThumbnailCache() {
        thumbnailCache.removeAll()
        thumbnailCacheOrder.removeAll()
        lastPreview = nil
    }

    // MARK: - Export

    func makeDragPayload(for item: CaptureItem) -> DraggedCapture {
        let dragged = selection.contains(item.handle) && selectedItems.count > 1
            ? selectedItems
            : [item]
        return DraggedCapture(items: dragged, service: service)
    }

    /// ⌘⇧E / File-menu export: straight to the remembered folder, or the
    /// folder picker on first use (the shortcut must not be dead on first run).
    func exportCommand() {
        let targets = exportTargets
        guard phase == .connected, !isExporting, !targets.isEmpty else { return }
        if let folder = rememberedExportFolder {
            beginExport(targets, to: folder)
        } else {
            pendingExportItems = targets
            exportPickerPresented = true
        }
    }

    func beginExport(_ itemsToExport: [CaptureItem], to directory: URL) {
        guard !isExporting else { return }
        exportTask = Task { [weak self] in
            await self?.export(itemsToExport, to: directory)
        }
    }

    func export(_ itemsToExport: [CaptureItem], to directory: URL) async {
        guard !itemsToExport.isEmpty, !isExporting else { return }
        TethersnapLog.info(TethersnapLog.app, "exporting \(itemsToExport.count) items to \(directory.path)")
        exportProgress = ExportProgress(completed: 0, total: itemsToExport.count, currentFraction: 0)
        exportSummary = nil
        let token = CancelToken()
        exportCancelToken = token
        let accessingScope = directory.startAccessingSecurityScopedResource()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Exporting Switch captures"
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
            if accessingScope { directory.stopAccessingSecurityScopedResource() }
            progressContinuation.finish()
            exportProgressTask = nil
            exportProgress = nil
            exportCancelToken = nil
            // Cells refused a thumbnail during the export re-request now.
            thumbnailGeneration += 1
        }

        do {
            let outcome = try await service.download(itemsToExport, to: directory, cancelToken: token) { completed, fraction in
                progressContinuation.yield((completed, fraction))
            }
            if outcome.cancelled {
                exportSummary = ExportSummary(
                    message: L10n.exportCancelled(outcome.saved),
                    folder: outcome.saved > 0 ? directory : nil
                )
                // A cancel mid-file abandons the PTP data phase; reconnect for a clean session.
                await connect()
            } else {
                rememberFolder(directory)
                exportSummary = ExportSummary(
                    message: Self.summaryMessage(outcome, folderName: directory.lastPathComponent),
                    folder: directory
                )
            }
        } catch {
            TethersnapLog.error(TethersnapLog.app, "export failed: \(error.localizedDescription)")
            exportSummary = ExportSummary(message: L10n.exportFailed(error.localizedDescription), folder: nil)
            // A transfer failure mid-object desynchronizes exactly like a
            // cancel; only a clean device response leaves the session usable.
            if case MTPError.deviceResponse = error {} else {
                await connect()
            }
        }
    }

    private static func summaryMessage(_ outcome: DeviceService.ExportOutcome, folderName: String) -> String {
        if outcome.skipped == 0 {
            L10n.exportSaved(outcome.saved, folder: folderName)
        } else if outcome.saved == 0 {
            L10n.exportAllExisted(outcome.skipped, folder: folderName)
        } else {
            L10n.exportSavedSkipped(saved: outcome.saved, skipped: outcome.skipped, folder: folderName)
        }
    }

    func cancelExport() {
        TethersnapLog.info(TethersnapLog.app, "export cancel requested")
        exportCancelToken?.cancel()
    }

    func dismissSummary() {
        exportSummary = nil
    }

    func revealInFinder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func revealLastExportInFinder() {
        guard let folder = rememberedExportFolder else { return }
        revealInFinder(folder)
    }

    func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([TethersnapLog.defaultLogFileURL])
    }

    // MARK: - Remembered folder

    private static func loadRememberedFolder() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastExportFolderKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    func rememberFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.lastExportFolderKey)
        rememberedExportFolder = url
    }

    func clearRememberedFolder() {
        UserDefaults.standard.removeObject(forKey: Self.lastExportFolderKey)
        rememberedExportFolder = nil
    }
}
