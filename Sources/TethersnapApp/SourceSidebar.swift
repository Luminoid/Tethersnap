import SwiftUI
import TethersnapKit

/// Devices, drives, and opened folders; selecting a row opens it. The open
/// source lists its folders beneath it (one per game on a console or a PS5
/// drive); selecting one narrows the grid to it.
struct SourceSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showsFolders = true

    var body: some View {
        @Bindable var model = model
        return List(selection: $model.sidebarSelection) {
            if !model.deviceSources.isEmpty {
                Section(L10n.sidebarDevices) {
                    ForEach(model.deviceSources) { sourceRow($0) }
                }
            }
            if !model.volumeSources.isEmpty {
                Section(L10n.sidebarDrives) {
                    ForEach(model.volumeSources) { sourceRow($0) }
                }
            }
            if !model.folderSources.isEmpty {
                Section(L10n.sidebarFolders) {
                    ForEach(model.folderSources) { sourceRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sources.isEmpty {
                Text(L10n.sidebarEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(Layout.spacingLarge)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.openFolderCommand()
            } label: {
                Label(L10n.menuOpenFolder, systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.isExporting || model.isPickingFolder)
            .padding(Layout.spacingMedium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The open source carries its folders as children once listed; a single
    /// folder is not listed, since choosing it would change nothing.
    @ViewBuilder
    private func sourceRow(_ descriptor: CaptureSourceDescriptor) -> some View {
        if descriptor.id == model.activeSource?.id, model.phase == .ready, model.folders.count >= 2 {
            DisclosureGroup(isExpanded: $showsFolders) {
                ForEach(model.folders) { folderRow($0) }
            } label: {
                row(descriptor)
            }
        } else {
            row(descriptor)
        }
    }

    /// An opened folder's row alone carries Remove from Sidebar; on the
    /// disclosure group it would reach the folder rows beneath it too.
    @ViewBuilder
    private func row(_ descriptor: CaptureSourceDescriptor) -> some View {
        let label = Label(descriptor.name, systemImage: descriptor.kind.symbolName)
            .lineLimit(1)
            .help(descriptor.detail ?? descriptor.name)
            .tag(AppModel.SidebarItem.source(descriptor.id))
        if descriptor.kind == .folder {
            label.contextMenu {
                Button(L10n.sidebarRemoveFolder) { model.removeFolder(descriptor) }
            }
        } else {
            label
        }
    }

    private func folderRow(_ folder: CaptureFolder) -> some View {
        Label(folder.name ?? L10n.groupOther, systemImage: "folder")
            .lineLimit(1)
            .badge(folder.count)
            .help(folder.name ?? L10n.groupOther)
            .tag(AppModel.SidebarItem.folder(folder.name))
    }
}

// MARK: - Symbols

extension CaptureSourceDescriptor.Kind {
    var symbolName: String {
        switch self {
        case .console: "gamecontroller"
        case .camera: "camera"
        case .ptpDevice: "iphone"
        case .volume: "externaldrive"
        case .folder: "folder"
        }
    }
}

extension AppModel.ViewMode {
    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .byFolder: "folder"
        }
    }
}
