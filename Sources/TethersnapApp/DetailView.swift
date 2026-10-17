import AppKit
import SwiftUI
import TethersnapKit

/// `.task(id:)` key for cell thumbnails: re-fires when the export that was
/// blocking thumbnail fetches ends (generation bump), not just per item.
struct ThumbnailRequest: Equatable {
    let id: CaptureItem.ID
    let generation: Int
}

/// Coordinate space shared by cell frames and the rubber-band drag. Named on
/// the grid content (which scrolls with the cells), so frames stay valid
/// mid-drag while the view scrolls.
enum GridSpace {
    static let name = "grid"
}

/// Collects every live cell's frame, keyed by capture ID. Recycled lazy
/// cells drop out automatically on the next preference pass.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [CaptureItem.ID: CGRect] = [:]

    static func reduce(value: inout [CaptureItem.ID: CGRect], nextValue: () -> [CaptureItem.ID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Live cell frames for the rubber band and the arrow keys. A reference box
/// rather than `@State` value storage: the preference fires for every lazy
/// row that appears during a scroll, and a value write there re-evaluated the
/// whole detail body (toolbar, O(N) labels) each time.
@MainActor
final class CellFrameStore {
    var frames: [CaptureItem.ID: CGRect] = [:]

    /// The cell in the row above (`direction` < 0) or below the anchor's
    /// frame that sits closest to it horizontally; nil when no such row is
    /// live (the anchor is in the first or last row).
    func neighbor(of anchor: CGRect, direction: Int) -> CaptureItem.ID? {
        // Distance along the travel direction, so the nearest row has the
        // smallest value for either direction.
        let distance: (CGRect) -> CGFloat = { direction > 0 ? $0.minY - anchor.maxY : anchor.minY - $0.maxY }
        let beyond = frames.filter { distance($0.value) >= 0 }
        guard let nearest = beyond.values.map(distance).min() else { return nil }
        let row = beyond.filter { distance($0.value) - nearest < 1 }
        return row.min { abs($0.value.midX - anchor.midX) < abs($1.value.midX - anchor.midX) }?.key
    }
}

/// The right pane: state screens or the capture grid, with the toolbar and
/// the status bar.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @State private var frames = CellFrameStore()
    @State private var rubberBand: CGRect?
    /// Selection when a rubber-band drag began (⇧/⌘ keep it, plain drag
    /// replaces); nil while no drag is running.
    @State private var rubberBandBase: Set<CaptureItem.ID>?
    /// The scroll view's height: the grid content is stretched to at least
    /// this, so the empty pane below a short grid is still grid space.
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        return Group {
            switch model.phase {
            case .noSource:
                NoSourceView()
            case .opening:
                OpeningView(name: model.activeSource?.name ?? "")
            case let .failed(message):
                FailedView(message: message)
            case .ready:
                gridView
            }
        }
        // Fill the window first: the state screens are fit-sized, and the
        // inset pins to the modified view's bounds, so without this the chip
        // hugs the centered text instead of the edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .navigationTitle(model.activeSource?.name ?? "Tethersnap")
        .navigationSubtitle(model.phase == .ready ? "\(L10n.capturesCount(model.filteredItems.count)) · \(model.totalSizeLabel)" : "")
        .toolbar(id: "main") {
            // Centered: the filter is the one control that changes what the
            // whole pane shows, so it sits in the middle like a tab strip.
            ToolbarItem(id: "filter", placement: .principal) {
                Picker(L10n.filterLabel, selection: $model.filter) {
                    ForEach(AppModel.Filter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .help(L10n.helpFilter)
                .disabled(model.phase != .ready)
            }

            ToolbarItem(id: "viewMode") {
                Picker(L10n.viewLabel, selection: $model.viewMode) {
                    ForEach(AppModel.ViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(L10n.helpViewMode)
                .disabled(model.phase != .ready)
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
                .disabled(model.phase != .ready)
            }

            ToolbarItem(id: "refresh") {
                Button(L10n.refresh, systemImage: "arrow.clockwise") {
                    model.beginRefresh()
                }
                .help(L10n.helpRefresh)
                .disabled(model.phase != .ready || model.isExporting)
            }

            ToolbarItem(id: "fixDates") {
                Button(L10n.fixDates, systemImage: "calendar.badge.clock") {
                    model.chooseDateFixFolder()
                }
                .help(L10n.helpFixDates)
                .disabled(model.isFixingDates || model.isPickingFolder)
            }

            // Trailing and prominent, with its title: the action most people
            // open the app for should not be one more glyph in the row.
            ToolbarItem(id: "export", placement: .primaryAction) {
                exportMenu
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var exportLabel: String {
        model.selection.isEmpty ? L10n.exportAll : L10n.exportCount(model.selectedItems.count)
    }

    @ViewBuilder
    private var gridView: some View {
        if model.filteredItems.isEmpty {
            emptyState
        } else {
            scrollGrid
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

    private var scrollGrid: some View {
        ScrollView {
            gridContent
                .padding(Layout.spacingXL)
                // Fill the viewport: a short grid leaves the rest of the pane
                // empty, and that space should still clear the selection on a
                // click and start a rubber band on a drag.
                .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
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
                .onPreferenceChange(CellFramesKey.self) { frames.frames = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            viewportHeight = height
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(rows: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(rows: 1); return .handled }
        .onKeyPress(.space) { model.previewSelected(); return .handled }
        .onKeyPress(.return) { model.previewSelected(); return .handled }
        .onKeyPress(.escape) { model.clearSelection(); return .handled }
        // Edit › Select All is the system ⌘A item; it reaches the focused grid here.
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
    }

    /// Up/Down move by a row: the cell nearest the anchor in the adjacent
    /// row, from live frames, so by-folder sections and a partial last row
    /// land where the eye expects. Without an anchor frame (nothing selected,
    /// or the anchor scrolled out of the live range) fall back to one step.
    private func moveSelection(rows direction: Int) {
        guard let anchor = model.selectionAnchor, let frame = frames.frames[anchor] else {
            model.moveSelection(by: direction)
            return
        }
        if let target = frames.neighbor(of: frame, direction: direction) {
            model.moveSelection(to: target)
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if model.viewMode == .byFolder {
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
        CaptureCell(item: item, isSelected: model.selection.contains(item.id)) {
            model.chooseExportFolder(for: [item])
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
                let hit = Set(frames.frames.filter { $0.value.intersects(rect) }.keys)
                model.selection = (rubberBandBase ?? []).union(hit)
            }
            .onEnded { _ in
                rubberBand = nil
                rubberBandBase = nil
            }
    }

    @ViewBuilder
    private var exportMenu: some View {
        let unavailable = model.phase != .ready || model.exportTargets.isEmpty || model.isExporting || model.isPickingFolder
        if let remembered = model.rememberedExportFolder {
            Menu {
                Button(L10n.exportToFolder(remembered.lastPathComponent)) {
                    model.exportCommand()
                }
                Button(L10n.chooseFolder) {
                    model.chooseExportFolder(for: model.exportTargets)
                }
            } label: {
                Label(exportLabel, systemImage: "square.and.arrow.down.on.square")
            } primaryAction: {
                model.exportCommand()
            }
            .disabled(unavailable)
            .help(L10n.helpExportRemembered(remembered.lastPathComponent))
        } else {
            Button {
                model.chooseExportFolder(for: model.exportTargets)
            } label: {
                Label(exportLabel, systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(unavailable)
            .help(L10n.helpExport)
        }
    }
}
