import AppKit
import SwiftUI
import TethersnapKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return Group {
            switch model.phase {
            case .waiting, .connecting:
                WaitingView(isConnecting: model.phase == .connecting)
            case let .failed(message):
                FailedView(message: message)
            case .connected:
                gridView
            }
        }
        // Fill the window first: the waiting/failed screens are fit-sized
        // VStacks, and the inset pins to the modified view's bounds, so
        // without this the chip hugs the centered text instead of the edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        .task { model.start() }
        .fileImporter(isPresented: $model.exportPickerPresented, allowedContentTypes: [.folder]) { result in
            let items = model.pendingExportItems
            model.pendingExportItems = []
            guard case let .success(url) = result else { return }
            model.beginExport(items, to: url)
        }
        .sheet(item: $model.previewItem) { item in
            PreviewSheet(item: item)
        }
    }

    private var exportLabel: String {
        model.selection.isEmpty ? L10n.exportAll : L10n.exportCount(model.selectedItems.count)
    }

    private var gridView: some View {
        @Bindable var model = model
        return Group {
            if model.filteredItems.isEmpty {
                emptyState
            } else {
                scrollGrid
            }
        }
        .navigationTitle(model.deviceName)
        .navigationSubtitle("\(L10n.capturesCount(model.filteredItems.count)) · \(model.totalSizeLabel)")
        .toolbar(id: "main") {
            ToolbarItem(id: "filter") {
                Picker(L10n.filterLabel, selection: $model.filter) {
                    ForEach(AppModel.Filter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            ToolbarItem(id: "viewMode") {
                Picker(L10n.viewLabel, selection: $model.viewMode) {
                    ForEach(AppModel.ViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(L10n.viewLabel)
            }

            ToolbarItem(id: "sort") {
                Menu {
                    Picker(L10n.sortLabel, selection: $model.sortOrder) {
                        ForEach(AppModel.SortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Label(L10n.sortLabel, systemImage: "arrow.up.arrow.down")
                }
                .help(L10n.helpSort)
            }

            ToolbarItem(id: "refresh") {
                Button(L10n.refresh, systemImage: "arrow.clockwise") {
                    model.beginRefresh()
                }
                .help(L10n.helpRefresh)
            }

            ToolbarItem(id: "export") {
                exportMenu
            }
        }
    }

    private var emptyState: some View {
        Group {
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.emptyTitle, systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(L10n.emptyMessage)
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.emptyFilterTitle, systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(L10n.emptyFilterMessage)
                }
            }
        }
        // Fill the window so the message centers instead of hugging its text.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var cellFrames: [UInt32: CGRect] = [:]
    @State private var rubberBand: CGRect?
    /// Selection when a rubber-band drag began (⇧/⌘ keep it, plain drag
    /// replaces); nil while no drag is running.
    @State private var rubberBandBase: Set<UInt32>?
    private var scrollGrid: some View {
        ScrollView {
            gridContent
                .padding(Layout.spacingXL)
                .background {
                    // Behind the cells, not an ancestor: clicks on a cell never
                    // reach it; clicks on empty grid space clear the selection,
                    // and drags from empty grid space rubber-band select.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                        .gesture(rubberBandGesture)
                }
                .overlay {
                    if let rect = rubberBand {
                        Rectangle()
                            .fill(Color.accentColor.opacity(Layout.rubberBandFillOpacity))
                            .overlay {
                                Rectangle()
                                    .strokeBorder(Color.accentColor.opacity(Layout.rubberBandStrokeOpacity), lineWidth: Layout.rubberBandLineWidth)
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: GridSpace.name)
                .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.space) { model.previewSelected(); return .handled }
        .onKeyPress(.return) { model.previewSelected(); return .handled }
        .onKeyPress(.escape) { model.clearSelection(); return .handled }
    }

    @ViewBuilder
    private var gridContent: some View {
        if model.viewMode == .byGame {
            LazyVGrid(columns: gridColumns, spacing: Layout.spacingMedium, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groupedItems) { group in
                    Section {
                        ForEach(group.items) { item in
                            captureCell(item)
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
        } else {
            LazyVGrid(columns: gridColumns, spacing: Layout.spacingMedium) {
                ForEach(model.filteredItems) { item in
                    captureCell(item)
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Layout.thumbnailSide), spacing: Layout.spacingMedium)]
    }

    private func captureCell(_ item: CaptureItem) -> some View {
        CaptureCell(item: item, isSelected: model.selection.contains(item.handle)) {
            model.pendingExportItems = [item]
            model.exportPickerPresented = true
        }
    }

    private func sectionHeader(_ group: AppModel.FolderGroup) -> some View {
        HStack(spacing: Layout.spacingSmall) {
            Label(group.name, systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
            Text(L10n.capturesCount(group.items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, Layout.spacingSmall)
        .background(.regularMaterial)
    }

    /// Finder-style drag-to-select: starts on empty grid space, selects every
    /// cell whose frame intersects the rectangle. ⇧/⌘ add to the existing
    /// selection; a plain drag replaces it.
    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: Layout.rubberBandThreshold, coordinateSpace: .named(GridSpace.name))
            .onChanged { value in
                if rubberBandBase == nil {
                    let modifiers = NSEvent.modifierFlags
                    rubberBandBase = modifiers.contains(.shift) || modifiers.contains(.command) ? model.selection : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                rubberBand = rect
                let hit = Set(cellFrames.filter { $0.value.intersects(rect) }.keys)
                model.selection = (rubberBandBase ?? []).union(hit)
            }
            .onEnded { _ in
                rubberBand = nil
                rubberBandBase = nil
            }
    }

    @ViewBuilder
    private var exportMenu: some View {
        if let remembered = model.rememberedExportFolder {
            Menu {
                Button(L10n.exportToFolder(remembered.lastPathComponent)) {
                    model.beginExport(model.exportTargets, to: remembered)
                }
                Button(L10n.chooseFolder) {
                    model.pendingExportItems = model.exportTargets
                    model.exportPickerPresented = true
                }
            } label: {
                Label(exportLabel, systemImage: "square.and.arrow.down.on.square")
            } primaryAction: {
                model.beginExport(model.exportTargets, to: remembered)
            }
            .disabled(model.exportTargets.isEmpty || model.isExporting)
            .help(L10n.helpExportRemembered(remembered.lastPathComponent))
        } else {
            Button {
                model.pendingExportItems = model.exportTargets
                model.exportPickerPresented = true
            } label: {
                Label(exportLabel, systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(model.exportTargets.isEmpty || model.isExporting)
            .help(L10n.helpExport)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let progress = model.exportProgress {
            HStack(spacing: Layout.spacingMedium) {
                ProgressView(value: progress.overallFraction)
                    .frame(maxWidth: Layout.progressBarWidth)
                Text(L10n.exportProgress(min(progress.completed + 1, progress.total), progress.total))
                    .font(.callout)
                    .monospacedDigit()
                Button(L10n.cancel) { model.cancelExport() }
                    .controlSize(.small)
            }
            .padding(Layout.spacingMedium)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .padding([.horizontal, .bottom], Layout.spacingLarge)
        } else if let summary = model.exportSummary {
            HStack(spacing: Layout.spacingMedium) {
                Text(summary.message)
                    .font(.callout)
                if let folder = summary.folder {
                    Button(L10n.showInFinder) { model.revealInFinder(folder) }
                        .controlSize(.small)
                }
                Button {
                    model.dismissSummary()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.close)
            }
            .padding(Layout.spacingMedium)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .padding([.horizontal, .bottom], Layout.spacingLarge)
        } else {
            HStack {
                Spacer()
                StatusChip()
            }
            .padding(.horizontal, Layout.spacingLarge)
            .padding(.bottom, Layout.spacingSmall)
        }
    }
}

/// `.task(id:)` key for cell thumbnails: re-fires when the export that was
/// blocking thumbnail fetches ends (generation bump), not just per handle.
private struct ThumbnailRequest: Equatable {
    let handle: UInt32
    let generation: Int
}

/// Coordinate space shared by cell frames and the rubber-band drag. Named on
/// the grid content (which scrolls with the cells), so frames stay valid
/// mid-drag while the view scrolls.
private enum GridSpace {
    static let name = "grid"
}

/// Collects every live cell's frame, keyed by capture handle. Recycled lazy
/// cells drop out automatically on the next preference pass.
private struct CellFramesKey: PreferenceKey {
    static let defaultValue: [UInt32: CGRect] = [:]

    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct CaptureCell: View {
    @Environment(AppModel.self) private var model
    let item: CaptureItem
    let isSelected: Bool
    let onExport: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            ZStack {
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .font(.system(size: Layout.iconPlaceholder))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: Layout.iconMedium))
                        .foregroundStyle(.white.opacity(Layout.badgeOpacity))
                        .shadow(radius: Layout.badgeShadowRadius)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: Layout.selectionLineWidth)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                        .strokeBorder(.tertiary, lineWidth: Layout.hoverLineWidth)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Layout.iconSmall))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(Layout.spacingXS)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: Layout.spacingXXS) {
                Text(item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? item.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(L10n.kindName(item.kind)) · \(CaptureFormat.size(item.sizeInBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: CellFramesKey.self, value: [item.handle: geo.frame(in: .named(GridSpace.name))])
            }
        }
        .onHover { isHovering = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            model.previewItem = item
        })
        .simultaneousGesture(TapGesture().onEnded {
            model.select(item, modifiers: NSEvent.modifierFlags)
        })
        .draggable(model.makeDragPayload(for: item))
        .contextMenu {
            Button(L10n.preview) { model.previewItem = item }
            Button(L10n.menuExport) { onExport() }
        }
        .task(id: ThumbnailRequest(handle: item.handle, generation: model.thumbnailGeneration)) {
            thumbnail = await model.thumbnail(for: item)
        }
        .help(item.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.kindName(item.kind)), \(item.filename)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: CaptureItem

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: Layout.spacingMedium) {
            Group {
                if item.kind == .video {
                    VStack(spacing: Layout.spacingSmall) {
                        Image(systemName: "film")
                            .font(.system(size: Layout.iconLarge))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(L10n.previewVideoHint)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    screenshotContent
                }
            }
            .frame(minWidth: Layout.previewMinWidth, minHeight: Layout.previewMinHeight)
            HStack {
                Text(item.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.filename)
                Spacer()
                Button(L10n.close) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Layout.spacingLarge)
        .task(id: attempt) { await load() }
    }

    @ViewBuilder
    private var screenshotContent: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel(item.filename)
        case let .failed(message):
            VStack(spacing: Layout.spacingSmall) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Layout.iconLarge))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: Layout.textColumnWidth)
                Button(L10n.retry) { attempt += 1 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard item.kind == .screenshot else { return }
        state = .loading
        do {
            state = try await .loaded(model.fullImage(for: item))
        } catch is CancellationError {
            // Sheet dismissed mid-load; nothing to show.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct WaitingView: View {
    let isConnecting: Bool

    var body: some View {
        VStack(spacing: Layout.spacingLarge) {
            if isConnecting {
                ProgressView()
                Text(L10n.connecting)
                    .font(.title3)
            } else {
                Image(systemName: "cable.connector")
                    .font(.system(size: Layout.iconLarge))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(L10n.waitingTitle)
                    .font(.title2)
                VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                    Label(L10n.waitingStep1, systemImage: "1.circle")
                    Label(L10n.waitingStep2, systemImage: "2.circle")
                    Label(L10n.waitingStep3, systemImage: "3.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: Layout.textColumnWidth, alignment: .leading)
            }
        }
        .padding(Layout.spacingXL)
    }
}

/// Colored dot + one line reflecting the connection state machine, so the app
/// always says what it currently sees (e.g. "No console detected on USB").
private struct StatusChip: View {
    @Environment(AppModel.self) private var model

    private var color: Color {
        switch model.phase {
        case .waiting: .gray
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    var body: some View {
        HStack(spacing: Layout.spacingSmall) {
            Circle()
                .fill(color)
                .frame(width: Layout.statusDotSize, height: Layout.statusDotSize)
            Text(model.statusLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: Layout.spacingLarge) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Layout.iconLarge))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(L10n.failedTitle)
                .font(.title2)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: Layout.textColumnWidth)
            Button(L10n.retry) {
                model.beginRetry()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(Layout.spacingXL)
    }
}
