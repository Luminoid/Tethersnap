import AppKit
import Foundation
import Observation
import TethersnapKit

/// UI state machine: no source → opening → ready grid, with export and
/// date-fix runs reported in the status bar. The runs live in
/// `AppModel+Export` and `AppModel+DateFix`, the published value types in
/// `AppModel+Types`, the UserDefaults keys in `AppPreferences`.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case noSource
        case opening
        case ready
        case failed(String)

        /// The case name alone; `failed`'s message is localized UI text.
        var logName: String {
            switch self {
            case .noSource: "noSource"
            case .opening: "opening"
            case .ready: "ready"
            case .failed: "failed"
            }
        }
    }

    /// What a source refresh is reacting to: a mount is the one event that
    /// auto-opens a volume, arrivals clear an old failure, polls do neither.
    private enum SourceEvent {
        case usb(USBDeviceWatcher.Event)
        case volume(VolumeWatcher.Event)
        case poll
    }

    private(set) var phase: Phase = .noSource
    /// Every source that can be opened: attached USB devices, mounted external
    /// volumes, then the opened folders that exist right now.
    private(set) var sources: [CaptureSourceDescriptor] = []
    /// The source being opened or shown; stays set on failure so Retry has a target.
    private(set) var activeSource: CaptureSourceDescriptor?
    /// Everything on the source; `filteredItems` is the visible slice.
    private(set) var items: [CaptureItem] = [] { didSet { updateFilteredItems() } }
    /// Memoized filter+sort result; recomputing per body access re-sorted the
    /// whole library several times per render. In by-folder mode this is the
    /// concatenation of `groupedItems`, so linear things (keyboard navigation,
    /// shift-click ranges, Export All) always follow the visual order.
    private(set) var filteredItems: [CaptureItem] = []
    /// Sections for by-folder mode, ordered by each folder's first item in the
    /// current sort; empty in flat mode.
    private(set) var groupedItems: [FolderGroup] = []
    /// Memoized beside `filteredItems`: the toolbar label, the export menu,
    /// and the drag payload all read these per render.
    private(set) var selectedItems: [CaptureItem] = []
    /// Items the export actions target: the selection when there is one,
    /// otherwise everything visible.
    private(set) var exportTargets: [CaptureItem] = []
    private(set) var totalSizeLabel = CaptureFormat.size(0)
    /// Last folder an export landed in, as remembered. Read from the
    /// preferences at launch and validated off main afterwards; `exportCommand`
    /// re-checks it at use because the drive may have been ejected since.
    private(set) var rememberedExportFolder: URL?
    /// Why the log file could not be opened this run (shown in the status bar);
    /// nil while file logging works.
    private(set) var logFileFailure: String?
    /// A folder panel is up; the commands that would stack a second one are
    /// disabled meanwhile (cancelling their task cannot dismiss `NSOpenPanel`).
    private(set) var isPickingFolder = false
    /// Last clicked or keyboard-reached item; shift-click ranges and arrow keys
    /// start here. Exposed so the grid can step by row from its frame.
    private(set) var selectionAnchor: CaptureItem.ID?
    var filter: Filter = .all { didSet { updateFilteredItems() } }
    var sortOrder: SortOrder = .newestFirst { didSet { updateFilteredItems() } }
    var viewMode: ViewMode = AppPreferences.viewMode {
        didSet {
            AppPreferences.saveViewMode(viewMode)
            updateFilteredItems()
        }
    }

    var selection: Set<CaptureItem.ID> = [] { didSet { updateSelectionDerived() } }
    /// PTP item shown in the custom preview sheet (no bytes on the Mac yet).
    var previewItem: CaptureItem?
    /// File-backed item shown by Quick Look.
    var quickLookURL: URL?
    var dateFixSheetPresented = false

    // MARK: - Run state

    // Written by the export and date-fix extensions, which live in other
    // files (so the setters cannot be private); views only read these.
    var exportProgress: ExportProgress?
    var exportSummary: ExportSummary?
    var dateFixProgress: DateFixProgress?
    var dateFixSummary: ExportSummary?
    /// The folder the date-fix sheet is about to run on.
    var dateFixFolder: URL?
    /// Bumped when a blocked thumbnail context ends (an export finishes) so
    /// visible cells re-request thumbnails they were refused.
    var thumbnailGeneration = 0
    let service = SourceService()
    var exportTask: Task<Void, Never>?
    var exportProgressTask: Task<Void, Never>?
    var dateFixTask: Task<Void, Never>?
    var dateFixProgressTask: Task<Void, Never>?
    var exportCancelToken: CancelToken?
    var dateFixCancelToken: CancelToken?

    /// The last discovery result; `sources` is this plus the available folders.
    private var attachedSources: [CaptureSourceDescriptor] = []
    /// Every folder the user opened, unavailable ones included (persisted as is).
    private var openedFolders: [CaptureSourceDescriptor] = []
    /// Opened folders that existed at the last probe; only these are listed.
    private var availableFolderIDs: Set<CaptureSourceDescriptor.ID> = []
    /// A source whose open the user cancelled: the poll must not re-open it
    /// until it is attached afresh.
    private var suppressedAutoOpenID: CaptureSourceDescriptor.ID?
    private var thumbnailCache: [CaptureItem.ID: NSImage] = [:]
    private var thumbnailCacheOrder: [CaptureItem.ID] = []
    private var lastPreview: (id: CaptureItem.ID, image: NSImage)?
    private var pollTask: Task<Void, Never>?
    private var sourceEventTask: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private var uiActionTask: Task<Void, Never>?
    private var usbWatcher: USBDeviceWatcher?
    private var volumeWatcher: VolumeWatcher?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    /// Bumped by every open and close; an actor result carrying an older
    /// generation belongs to a superseded open and is dropped.
    private var openGeneration = 0
    /// Single-flight guard for `recoverIfSessionDied`: every thumbnail task
    /// that fails on a dead session calls it, and one reopen is enough.
    private var isRecovering = false

    /// `Tethersnap 0.2.0 (2), macOS 26.0.0`: the first line of every run's log.
    private static var versionHeader: String {
        let info = Bundle.main.infoDictionary
        // A bare `swift run TethersnapApp` has no bundle Info.plist.
        let version = info?["CFBundleShortVersionString"] as? String ?? TethersnapVersion.current
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Tethersnap \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    // MARK: - Derived state

    /// Sidebar selection. Writes open the chosen source; nil (a click on empty
    /// sidebar space) keeps the current one.
    var activeSourceID: CaptureSourceDescriptor.ID? {
        get { activeSource?.id }
        set {
            guard let newValue, newValue != activeSource?.id, !isExporting,
                  let descriptor = sources.first(where: { $0.id == newValue }) else { return }
            beginOpen(descriptor)
        }
    }

    var deviceSources: [CaptureSourceDescriptor] { sources.filter(\.kind.isUSB) }
    var volumeSources: [CaptureSourceDescriptor] { sources.filter { $0.kind == .volume } }
    var folderSources: [CaptureSourceDescriptor] { sources.filter { $0.kind == .folder } }

    var isExporting: Bool { exportProgress != nil }
    var isFixingDates: Bool { dateFixProgress != nil }

    /// One-line status for the persistent status chip.
    var statusLabel: String {
        switch phase {
        case .noSource:
            L10n.statusNoSource
        case .opening:
            L10n.statusOpening(activeSource?.name ?? "")
        case .ready:
            if let activeSource, activeSource.kind.isUSB {
                L10n.statusConnected(activeSource.name, activeSource.detail ?? "")
            } else {
                L10n.statusShowing(activeSource?.name ?? "")
            }
        case .failed:
            L10n.statusFailed
        }
    }

    private func updateFilteredItems() {
        let visible = sortOrder.sorted(items.matching(filter.kind))
        if viewMode == .byFolder {
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
        totalSizeLabel = CaptureFormat.size(filteredItems.reduce(0) { $0 + $1.sizeInBytes })
        // A selection must never target something the visible list (and the
        // "Export N" label) doesn't show. The selection's own didSet refreshes
        // the derived lists; an unchanged selection still needs the new order.
        let kept = selection.intersection(filteredItems.map(\.id))
        if kept != selection {
            selection = kept
        } else {
            updateSelectionDerived()
        }
    }

    private func updateSelectionDerived() {
        selectedItems = selection.isEmpty ? [] : filteredItems.filter { selection.contains($0.id) }
        exportTargets = selection.isEmpty ? filteredItems : selectedItems
    }

    // MARK: - Lifecycle

    /// IOKit and mount notifications drive arrival/removal; a slow poll stays
    /// as a safety net in case a notification is missed.
    func start() {
        guard pollTask == nil else { return }
        // Every run leaves a full debug trace on disk (previous run kept), so
        // bug reports never depend on having had `log stream` running. A
        // failure is already logged; the status bar says so without blocking.
        // The version header goes first so it opens every run's file.
        let logURL: URL?
        do {
            logURL = try TethersnapLog.enableFileLogging()
        } catch {
            logURL = nil
            logFileFailure = error.localizedDescription
        }
        TethersnapLog.notice(.app, "\(Self.versionHeader), watching for sources")
        if let logURL {
            TethersnapLog.info(.app, "file log enabled", private: logURL.path)
        }
        // Stored paths only; whether they exist is probed off main below. A
        // remembered folder on an unmounted share would otherwise hold the
        // first frame for the mount timeout.
        rememberedExportFolder = AppPreferences.rememberedExportFolder
        openedFolders = AppPreferences.openedFolders
        rebuildSources()
        volumeWatcher = VolumeWatcher { [weak self] event in
            Task { @MainActor [weak self] in
                self?.enqueueSourceEvent(.volume(event))
            }
        }
        memoryPressureSource = makeMemoryPressureSource()
        // Startup housekeeping off main: reap stale drag folders, probe the
        // remembered paths, then build the USB watcher (IOKit registration
        // IPC). The bridging Task inside the handler only hops to the main
        // actor, where the real work runs in the stored, cancel-and-replace
        // `sourceEventTask`.
        let remembered = rememberedExportFolder
        let probed = openedFolders.compactMap(\.folderURL) + (remembered.map { [$0] } ?? [])
        housekeepingTask = Task.detached(priority: .utility) { [weak self] in
            SourceService.reapDragTemporaries()
            let existing = await SourceService.existingDirectories(among: probed)
            // Strong rebind only for the duration of this short-lived task;
            // the watcher handler itself captures weakly.
            guard let self else { return }
            let watcher = USBDeviceWatcher { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.enqueueSourceEvent(.usb(event))
                }
            }
            await finishStartup(usbWatcher: watcher, probed: probed, existing: existing, remembered: remembered)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refreshSources(trigger: .poll)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Cancel background work and release the watchers (paired with
    /// `start()`; the app calls it on termination).
    func stop() {
        for task in [pollTask, sourceEventTask, housekeepingTask, uiActionTask, exportTask, exportProgressTask, dateFixTask, dateFixProgressTask] {
            task?.cancel()
        }
        pollTask = nil
        sourceEventTask = nil
        housekeepingTask = nil
        uiActionTask = nil
        exportTask = nil
        exportProgressTask = nil
        dateFixTask = nil
        dateFixProgressTask = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        usbWatcher?.invalidate()
        usbWatcher = nil
        volumeWatcher?.invalidate()
        volumeWatcher = nil
    }

    /// Synchronous main-actor part of app termination: cancel everything and
    /// hand the service back so the delegate can attempt a *bounded*,
    /// off-main close. Termination must never await this actor's
    /// availability: a wedged USB call would hold quit hostage (bit us).
    func beginTerminationCleanup() -> SourceService {
        exportCancelToken?.cancel()
        dateFixCancelToken?.cancel()
        stop()
        return service
    }

    /// Cancel-and-replace slot for user-initiated async work (opens, retries,
    /// folder panels): a newer action supersedes an older one still in flight.
    func runUIAction(_ body: @escaping @MainActor (AppModel) async -> Void) {
        uiActionTask?.cancel()
        uiActionTask = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    /// Run the folder panel for a command. One panel at a time: the commands
    /// that open one are disabled while `isPickingFolder` is set.
    func pickFolder(initial: URL?, message: String, prompt: String, canCreateDirectories: Bool = false) async -> URL? {
        guard !isPickingFolder else { return nil }
        isPickingFolder = true
        defer { isPickingFolder = false }
        return await FolderPicker.choose(initial: initial, message: message, prompt: prompt, canCreateDirectories: canCreateDirectories)
    }

    private func makeMemoryPressureSource() -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            // Delivered on the main queue, so the assumption holds.
            MainActor.assumeIsolated {
                guard let self else { return }
                // The system signal arrives with nothing cached too; only a
                // real drop is worth a notice line.
                if self.thumbnailCache.isEmpty, self.lastPreview == nil {
                    TethersnapLog.debug(.app, "memory pressure; nothing cached to drop")
                } else {
                    TethersnapLog.notice(.app, "memory pressure; dropping \(self.thumbnailCache.count) cached thumbnails")
                }
                self.clearThumbnailCache()
            }
        }
        source.activate()
        return source
    }

    private func finishStartup(usbWatcher watcher: USBDeviceWatcher?, probed: [URL], existing: Set<String>, remembered: URL?) {
        guard pollTask != nil else {
            watcher?.invalidate()
            return
        }
        if watcher == nil {
            TethersnapLog.warning(.app, "no USB device watcher; relying on the 5 s poll for arrivals and removals")
        }
        usbWatcher = watcher
        applyFolderAvailability(probed: probed, existing: existing)
        // Only the folder that was probed: an export may have replaced it meanwhile.
        if let remembered, !existing.contains(remembered.path), rememberedExportFolder == remembered {
            TethersnapLog.notice(.app, "the remembered export folder is gone; forgetting it")
            clearRememberedFolder()
        }
    }

    private func enqueueSourceEvent(_ event: SourceEvent) {
        sourceEventTask?.cancel()
        sourceEventTask = Task { [weak self] in
            await self?.refreshSources(trigger: event)
        }
    }

    // MARK: - Sources

    private func rebuildSources() {
        let rebuilt = attachedSources + openedFolders.filter { availableFolderIDs.contains($0.id) }
        // The 5 s poll lands here; an unchanged list must not invalidate the sidebar.
        if rebuilt != sources {
            sources = rebuilt
        }
    }

    /// Record which probed folders exist; folders outside `probed` keep their
    /// state (one added while the probe ran stays listed).
    private func applyFolderAvailability(probed: [URL], existing: Set<String>) {
        let probedPaths = Set(probed.map(\.path))
        for folder in openedFolders {
            guard let url = folder.folderURL, probedPaths.contains(url.path) else { continue }
            if existing.contains(url.path) {
                availableFolderIDs.insert(folder.id)
            } else {
                availableFolderIDs.remove(folder.id)
            }
        }
        rebuildSources()
    }

    /// Re-enumerate what is attached, drop a vanished active source, and
    /// auto-open when nothing is open: the first console or camera (never a
    /// phone), or the volume that just mounted.
    private func refreshSources(trigger: SourceEvent) async {
        switch trigger {
        case .usb(.attached), .volume(.mounted):
            suppressedAutoOpenID = nil
            // A fresh arrival (replug, the stale-session USB reset, a card
            // inserted) supersedes an old failure; give it a clean try.
            if case .failed = phase {
                TethersnapLog.info(.app, "arrival clears the earlier failure")
                phase = .noSource
                activeSource = nil
            }
        default:
            break
        }
        attachedSources = await service.attachedSources()
        if case .volume = trigger {
            // Opened folders on an external drive come and go with it; the
            // remembered export folder too, so an unmount re-checks that one.
            var probed = openedFolders.compactMap(\.folderURL)
            let remembered = rememberedExportFolder
            if case .volume(.unmounted) = trigger, let remembered {
                probed.append(remembered)
            }
            let existing = await SourceService.existingDirectories(among: probed)
            applyFolderAvailability(probed: probed, existing: existing)
            if case .volume(.unmounted) = trigger, let remembered, !existing.contains(remembered.path), rememberedExportFolder == remembered {
                TethersnapLog.notice(.app, "the remembered export folder is gone; forgetting it")
                clearRememberedFolder()
            }
        }
        rebuildSources()
        if let active = activeSource, !sources.contains(where: { $0.id == active.id }) {
            TethersnapLog.notice(.app, "\(active.logName) is gone", private: active.logDetail)
            await closeToNoSource(detached: true)
        }
        if let suppressed = suppressedAutoOpenID, !sources.contains(where: { $0.id == suppressed }) {
            suppressedAutoOpenID = nil
        }
        guard phase == .noSource else { return }
        if let device = sources.first(where: { ($0.kind == .console || $0.kind == .camera) && $0.id != suppressedAutoOpenID }) {
            await open(device)
        } else if case let .volume(.mounted(mounted)) = trigger, sources.contains(where: { $0.id == mounted.id }) {
            await open(mounted)
        }
    }

    func beginOpen(_ descriptor: CaptureSourceDescriptor) {
        runUIAction { await $0.open(descriptor) }
    }

    func open(_ descriptor: CaptureSourceDescriptor) async {
        openGeneration += 1
        let generation = openGeneration
        suppressedAutoOpenID = nil
        TethersnapLog.notice(.app, "opening \(descriptor.logName) (was \(phase.logName))", private: descriptor.logDetail)
        activeSource = descriptor
        phase = .opening
        resetSourceState()
        do {
            let opened = try await service.open(descriptor)
            guard generation == openGeneration else {
                TethersnapLog.info(.app, "dropping the result of a superseded open of \(descriptor.logName)", private: descriptor.logDetail)
                return
            }
            activeSource = opened.descriptor
            items = opened.items
            phase = .ready
            // A USB detail is the firmware; a drive's or folder's is its path.
            let firmware = opened.descriptor.kind.isUSB ? " (\(opened.descriptor.detail ?? ""))" : ""
            TethersnapLog.notice(.app, "opened \(opened.descriptor.logName)\(firmware), \(opened.items.count) captures", private: opened.descriptor.logDetail)
        } catch {
            guard generation == openGeneration else {
                // The newer open owns the service now; its own open closed this one.
                TethersnapLog.info(.app, "dropping the failure of a superseded open of \(descriptor.logName)", private: descriptor.logDetail)
                return
            }
            await service.close()
            TethersnapLog.error(.app, "open failed for \(descriptor.logName)", private: descriptor.logDetail, error: error)
            phase = .failed(error.localizedDescription)
        }
    }

    /// Cancel on the opening screen: back to no source at once. The actor call
    /// itself runs to completion (a USB handshake cannot be interrupted), its
    /// result is dropped as stale, and the poll leaves the source alone until
    /// it is attached afresh.
    func cancelOpen() {
        guard phase == .opening, let activeSource else { return }
        TethersnapLog.notice(.app, "open of \(activeSource.logName) cancelled", private: activeSource.logDetail)
        suppressedAutoOpenID = activeSource.id
        runUIAction { await $0.closeToNoSource() }
    }

    func retry() async {
        TethersnapLog.notice(.app, "retry requested (was \(phase.logName))")
        if let activeSource {
            await open(activeSource)
        } else {
            phase = .noSource
            await refreshSources(trigger: .poll)
        }
    }

    func beginRefresh() {
        runUIAction { await $0.refresh() }
    }

    func beginRetry() {
        runUIAction { await $0.retry() }
    }

    func refresh() async {
        guard phase == .ready, !isExporting else { return }
        do {
            items = try await service.reloadItems()
        } catch {
            // Losing the grid silently looks like a wipe; explain and offer Retry.
            TethersnapLog.error(.app, "refresh failed", error: error)
            await service.close()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Everything scoped to the open source: items, selection, caches,
    /// previews, and both summaries (a stale "Updated N files" chip must not
    /// survive a source switch).
    private func resetSourceState() {
        items = []
        selection = []
        selectionAnchor = nil
        clearThumbnailCache()
        previewItem = nil
        quickLookURL = nil
        exportSummary = nil
        dateFixSummary = nil
    }

    /// UI first, then the close: the actor may be inside a long open, and the
    /// generation bump makes that open's result stale. `detached`: the source
    /// is already gone, so no CloseSession goes to a device that cannot answer.
    private func closeToNoSource(detached: Bool = false) async {
        openGeneration += 1
        resetSourceState()
        activeSource = nil
        phase = .noSource
        TethersnapLog.notice(.app, "no source open")
        await service.close(detached: detached)
    }

    /// Reopen when a swallowed-looking failure actually killed a PTP session
    /// (a desynchronized session cannot be resumed, only rebuilt). Single
    /// flight: every in-flight thumbnail task fails on the dead session and
    /// calls this, and the first reopen serves them all.
    private func recoverIfSessionDied() async {
        guard !isRecovering, phase == .ready, let activeSource, activeSource.kind.isUSB else { return }
        isRecovering = true
        defer { isRecovering = false }
        let sourceID = activeSource.id
        guard await !service.isValid() else { return }
        // Re-checked after the await: the user may have switched sources meanwhile.
        guard phase == .ready, self.activeSource?.id == sourceID else { return }
        TethersnapLog.warning(.app, "session invalidated; reopening \(activeSource.logName)")
        await open(activeSource)
    }

    // MARK: - Folders

    /// File › Open Folder…: pick a folder, list it in the sidebar, and open it.
    func openFolderCommand() {
        guard !isExporting, !isPickingFolder else { return }
        runUIAction { model in
            guard let url = await model.pickFolder(initial: nil, message: L10n.openFolderPanelMessage, prompt: L10n.openFolderPanelPrompt) else { return }
            // Unsandboxed app: a plain path, no security-scoped access to start.
            let descriptor = model.addFolder(url)
            await model.open(descriptor)
        }
    }

    @discardableResult
    func addFolder(_ url: URL) -> CaptureSourceDescriptor {
        let descriptor = CaptureSourceDescriptor.folder(url)
        if !openedFolders.contains(where: { $0.id == descriptor.id }) {
            openedFolders.append(descriptor)
            AppPreferences.saveOpenedFolders(openedFolders)
        }
        // Just chosen in the panel, so it exists; no filesystem probe on main.
        availableFolderIDs.insert(descriptor.id)
        rebuildSources()
        return descriptor
    }

    func removeFolder(_ descriptor: CaptureSourceDescriptor) {
        openedFolders.removeAll { $0.id == descriptor.id }
        availableFolderIDs.remove(descriptor.id)
        AppPreferences.saveOpenedFolders(openedFolders)
        rebuildSources()
        guard activeSource?.id == descriptor.id, !isExporting else { return }
        runUIAction { await $0.closeToNoSource() }
    }

    // MARK: - Remembered folder

    func rememberFolder(_ url: URL) {
        AppPreferences.saveRememberedExportFolder(url)
        rememberedExportFolder = url
    }

    func clearRememberedFolder() {
        AppPreferences.saveRememberedExportFolder(nil)
        rememberedExportFolder = nil
    }

    // MARK: - Selection

    func select(_ item: CaptureItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let anchorIndex = filteredItems.firstIndex(where: { $0.id == anchor }),
           let itemIndex = filteredItems.firstIndex(where: { $0.id == item.id }) {
            let range = min(anchorIndex, itemIndex) ... max(anchorIndex, itemIndex)
            selection = Set(filteredItems[range].map(\.id))
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else {
            selection = [item.id]
        }
        selectionAnchor = item.id
    }

    func selectAll() {
        selection = Set(filteredItems.map(\.id))
    }

    func clearSelection() {
        selection = []
    }

    /// Arrow-key navigation: move a single selection through the visible order.
    func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        let currentIndex = selectionAnchor.flatMap { anchor in
            filteredItems.firstIndex { $0.id == anchor }
        }
        let newIndex = currentIndex.map { max(0, min(filteredItems.count - 1, $0 + offset)) } ?? 0
        moveSelection(to: filteredItems[newIndex].id)
    }

    /// Up/Down arrows: the grid picks the cell in the adjacent row from its
    /// live frames and lands here.
    func moveSelection(to id: CaptureItem.ID) {
        selection = [id]
        selectionAnchor = id
    }

    /// Preview the current selection anchor (Space, Return, ⌘Y).
    func previewSelected() {
        guard let anchor = selectionAnchor,
              let item = filteredItems.first(where: { $0.id == anchor }) else { return }
        preview(item)
    }

    /// Files go to Quick Look (videos play, RAW and HEIC render natively); a
    /// PTP item has no bytes on the Mac yet and uses the custom sheet.
    func preview(_ item: CaptureItem) {
        if let url = item.fileURL {
            quickLookURL = url
        } else {
            previewItem = item
        }
    }

    // MARK: - Thumbnails

    func thumbnail(for item: CaptureItem) async -> NSImage? {
        if let cached = thumbnailCache[item.id] { return cached }
        guard phase == .ready, !isExporting else { return nil }
        do {
            guard let payload = try await service.thumbnailPayload(for: item) else { return nil }
            if let image = await Thumbnailer.downsample(payload.data, maxPixel: 480) {
                cacheThumbnail(image, for: item.id)
                return image
            }
            // A bounded prefix that didn't decode; fetch the whole image once.
            if !payload.isComplete {
                let full = try await service.fullImageData(for: item)
                if let image = await Thumbnailer.downsample(full, maxPixel: 480) {
                    cacheThumbnail(image, for: item.id)
                    return image
                }
                TethersnapLog.warning(.app, "thumbnail did not decode (\(payload.data.count)-byte prefix, then \(full.count) bytes in full)", private: item.filename)
            } else {
                TethersnapLog.warning(.app, "thumbnail did not decode (\(payload.data.count) bytes)", private: item.filename)
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            TethersnapLog.error(.app, "thumbnail failed", private: item.filename, error: error)
            await recoverIfSessionDied()
            return nil
        }
    }

    /// Full-resolution image for the preview sheet (images only). Throws so
    /// the sheet can show the failure instead of spinning forever.
    func fullImage(for item: CaptureItem) async throws -> NSImage {
        if let lastPreview, lastPreview.id == item.id { return lastPreview.image }
        guard item.kind == .image, phase == .ready else { throw CaptureSourceError.noOpenSource }
        do {
            let data = try await service.fullImageData(for: item)
            // Downsample off-main to display scale; a raw NSImage(data:) would
            // decode the full 4K JPEG on the main thread at draw time.
            guard let image = await Thumbnailer.downsample(data, maxPixel: 2560) else {
                throw MTPError.malformedData("preview image failed to decode")
            }
            lastPreview = (item.id, image)
            return image
        } catch {
            TethersnapLog.error(.app, "preview failed", private: item.filename, error: error)
            await recoverIfSessionDied()
            throw error
        }
    }

    private func cacheThumbnail(_ image: NSImage, for id: CaptureItem.ID) {
        if thumbnailCache[id] == nil {
            thumbnailCacheOrder.append(id)
        }
        thumbnailCache[id] = image
        // Simple FIFO bound; evicted thumbnails are re-fetchable from the
        // source. Memory pressure empties the whole cache (see `start()`).
        while thumbnailCacheOrder.count > 300 {
            thumbnailCache.removeValue(forKey: thumbnailCacheOrder.removeFirst())
        }
    }

    private func clearThumbnailCache() {
        thumbnailCache.removeAll()
        thumbnailCacheOrder.removeAll()
        lastPreview = nil
    }
}
